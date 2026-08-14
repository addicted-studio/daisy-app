//
//  AgentCLISummarizer.swift
//  Daisy
//
//  Summaries through a coding-agent CLI the user already has logged in —
//  Claude Code (`claude -p`) or Codex (`codex exec`). No API key: the
//  agent authenticates with the user's own Claude or ChatGPT
//  subscription, and the request counts against that plan's limits.
//
//  WHY A SUBPROCESS AND NOT MCP. The elegant version of this is MCP
//  sampling: Daisy's MCP server asks the connected client (Claude
//  Desktop) to run the completion on the user's subscription. The
//  protocol has `sampling/createMessage` for exactly this — but Claude
//  Desktop has never implemented sampling, so the call has nobody to
//  answer it. Both agent CLIs ship a documented non-interactive mode.
//  So: a subprocess. (Daisy is not sandboxed — see Daisy.entitlements —
//  so it can spawn one; `MCPSummarizer` stayed HTTP-only for that
//  reason. No extra entitlement is needed to exec a separate binary.)
//
//  FOUR THINGS THIS FILE IS CAREFUL ABOUT.
//
//  1. BILLING IS NOT GUARANTEED TO BE FREE, and Daisy must never imply
//     it is. Both CLIs have open reports of headless runs billing as
//     metered API usage when the account also has API access — one user
//     reported four figures in two days. The settings copy says to check
//     usage after the first run. We do not promise "free", and we record
//     nothing to TokenLedger because the agent reports no usage we can
//     price.
//
//  2. THESE ARE AGENTS, NOT MODELS. Left alone, `claude -p` can read
//     files and run commands. Every invocation disables tools and runs
//     in an empty temporary directory. Note the containment is NOT
//     total: HOME is inherited (it must be — that's where the CLI keeps
//     its credentials), so user-scope config still loads. If a user's
//     global instructions ever corrupt summaries, the next lever is the
//     CLIs' own "ignore user config" flags — deliberately not passed
//     blind here, because an unsupported flag makes the CLI exit with a
//     usage error and kills the feature outright.
//
//  3. THE TRANSCRIPT LEAVES THE MAC. It goes to Anthropic or OpenAI
//     under the user's own account. No worse than the API-key
//     providers, but not local — `privacyTag` says so plainly. The
//     request being relayed by an app on the user's own machine must not
//     read as "stays on my Mac".
//
//  4. A GUI APP'S ENVIRONMENT IS NOT A TERMINAL'S. Launched from Finder,
//     Daisy inherits `PATH=/usr/bin:/bin:/usr/sbin:/sbin` — no Homebrew,
//     no `~/.local/bin`. The npm-installed `claude` is a `#!/usr/bin/env
//     node` shim, so finding the shim isn't enough: the CHILD needs a
//     PATH that can find node, or it dies with exit 127. That is the
//     single likeliest way this feature would "work in Terminal, do
//     nothing in Daisy".
//

import Darwin
import Foundation
import os

/// Which agent CLI to drive. Raw values persist in UserDefaults.
enum AgentCLIKind: String, Codable, CaseIterable, Sendable {
    case claudeCode
    case codex

    var displayName: String {
        switch self {
        case .claudeCode: return String(localized: "Claude Code")
        case .codex: return String(localized: "Codex")
        }
    }

    /// Executable name as found on `PATH`.
    var executableName: String {
        switch self {
        case .claudeCode: return "claude"
        case .codex: return "codex"
        }
    }

    /// Where each installer puts the binary. Checked in order before we
    /// fall back to asking a login shell.
    var likelyPaths: [String] {
        let home = NSHomeDirectory()
        switch self {
        case .claudeCode:
            return [
                "\(home)/.local/bin/claude",
                "\(home)/.claude/local/claude",
                "/opt/homebrew/bin/claude",
                "/usr/local/bin/claude",
            ]
        case .codex:
            return [
                "\(home)/.local/bin/codex",
                "/opt/homebrew/bin/codex",
                "/usr/local/bin/codex",
            ]
        }
    }

    /// Arguments for a single non-interactive completion reading the
    /// prompt from stdin.
    ///
    /// - Claude Code: `--tools ""` is what actually restricts the tool
    ///   set. (`--allowedTools` only pre-approves tools that would
    ///   otherwise prompt — it does NOT take them away, which is the
    ///   opposite of what a summarizer wants.)
    /// - Codex: `--skip-git-repo-check` is REQUIRED — `codex exec`
    ///   refuses to run outside a Git repository, and our scratch dir is
    ///   a bare temp folder. Without it the feature fails 100% of the
    ///   time.
    func arguments(lastMessageFile: URL) -> [String] {
        switch self {
        case .claudeCode:
            return ["-p", "--tools", "", "--output-format", "text"]
        case .codex:
            // `-o` writes just the final answer to a file, keeping us
            // off Codex's stdout event log.
            return [
                "exec",
                "--skip-git-repo-check",
                "--sandbox", "read-only",
                "-o", lastMessageFile.path,
                "-",
            ]
        }
    }

    /// Whether the answer is read from `lastMessageFile` rather than
    /// stdout.
    var readsAnswerFromFile: Bool { self == .codex }
}

nonisolated struct AgentCLISummarizer: SummaryProvider {
    let kind: SummaryProviderKind = .agentCLI

    let agent: AgentCLIKind
    /// User-supplied absolute path, when auto-detection can't find the
    /// binary (a version manager, an unusual prefix). Empty = auto.
    let executableOverride: String

    /// Generous: the agent boots a runtime, authenticates, and may
    /// retry — and a long meeting is a big prompt. Still bounded, so a
    /// hung agent can't wedge the finalize pipeline.
    private static let timeout: TimeInterval = 180
    /// Hard cap on the login-shell lookup. A `.zshrc` with nvm/conda/mise
    /// routinely takes seconds; forever is not an option on any path
    /// that can reach the main actor.
    private static let shellProbeTimeout: TimeInterval = 3

    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "AgentCLI")

    init(agent: AgentCLIKind, executableOverride: String = "") {
        self.agent = agent
        self.executableOverride = executableOverride
    }

    // MARK: - Locating the binary

    /// Resolve the executable, or `nil` when it isn't installed where we
    /// can see it. BLOCKING (the last resort spawns a login shell) —
    /// never call this from the main actor; see `isReady`.
    func resolvedExecutable() -> String? {
        let fm = FileManager.default
        let override = executableOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty {
            return fm.isExecutableFile(atPath: override) ? override : nil
        }
        for path in agent.likelyPaths where fm.isExecutableFile(atPath: path) {
            return path
        }
        return Self.whichViaLoginShell(agent.executableName)
    }

    /// Ask a login shell where the binary is — it sources the user's
    /// profile and therefore knows about version managers we'd never
    /// guess. Bounded: a slow profile must not hang the app.
    private static func whichViaLoginShell(_ name: String) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "command -v \(name)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        let deadline = Date().addingTimeInterval(shellProbeTimeout)
        while process.isRunning, Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0,
              let out = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !out.isEmpty,
              FileManager.default.isExecutableFile(atPath: out)
        else { return nil }
        return out
    }

    /// `Task.detached` because the lookup blocks and, under this
    /// target's approachable-concurrency setting, a `nonisolated async`
    /// func would otherwise inherit the CALLER's isolation — and the
    /// caller (`Summarizer.refreshAvailability`) is `@MainActor`. That
    /// would put a login shell on the main thread at every launch.
    func isReady() async -> Bool {
        let probe = self
        return await Task.detached(priority: .utility) {
            probe.resolvedExecutable() != nil
        }.value
    }

    /// PATH for the CHILD. The resolved binary's own directory first (a
    /// version manager's shim lives next to its runtime), then the usual
    /// install prefixes, then the system default. Without this an
    /// npm-installed `claude` can't find `node` and exits 127.
    private static func childPath(for executable: String) -> String {
        var parts = [URL(fileURLWithPath: executable).deletingLastPathComponent().path]
        let home = NSHomeDirectory()
        parts += [
            "\(home)/.local/bin",
            "\(home)/.bun/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        if let inherited = ProcessInfo.processInfo.environment["PATH"], !inherited.isEmpty {
            parts.append(inherited)
        }
        var seen = Set<String>()
        return parts.filter { seen.insert($0).inserted }.joined(separator: ":")
    }

    // MARK: - Summarize

    func summarize(
        transcript: String,
        title: String,
        localeHint: String?,
        task: SummaryTask
    ) async throws -> MeetingSummary {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 40 else {
            throw SummaryProviderError.transcriptTooShort
        }
        let executable = await Task.detached(priority: .userInitiated) { [self] in
            resolvedExecutable()
        }.value
        guard let executable else {
            throw SummaryProviderError.modelUnavailable(
                provider: agent.displayName,
                reason: String(localized: "Not installed, or Daisy can’t see it. Install the CLI and sign in, or set its path in Settings → Summary.")
            )
        }

        // Same prompt every other provider gets — the agent is just a
        // different pipe to a model, so the summary shape stays
        // identical across providers.
        let system = SummaryPrompt.systemInstructions(localeHint: localeHint, task: task)
        let user = SummaryPrompt.userPrompt(title: title, transcript: trimmed, task: task)
        let prompt = system + "\n\n" + user

        let output = try await run(executable: executable, prompt: prompt)
        return try parse(output)
    }

    /// Spawn the agent, write the prompt to stdin, read the answer.
    ///
    /// Runs in an EMPTY temporary directory: these CLIs treat the working
    /// directory as their project context, and pointing one at the user's
    /// home would hand a summarizer a filesystem.
    private func run(executable: String, prompt: String) async throws -> String {
        // Writing to a pipe whose reader has exited raises SIGPIPE, which
        // kills the process by default. Ignoring it turns that into an
        // EPIPE error we can handle — and the agent exiting early (not
        // signed in) while we're still writing a 100 KB prompt is the
        // most likely first-run failure there is.
        _ = Self.ignoreSIGPIPEOnce

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("daisy-agent-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        } catch {
            throw SummaryProviderError.modelUnavailable(
                provider: agent.displayName,
                reason: String(localized: "Couldn’t create a temporary working folder for the agent.")
            )
        }
        defer { try? FileManager.default.removeItem(at: scratch) }
        let answerFile = scratch.appendingPathComponent("answer.txt")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = agent.arguments(lastMessageFile: answerFile)
        process.currentDirectoryURL = scratch

        // Inherit the environment (HOME is where the CLI keeps its
        // credentials) but fix PATH, and strip API keys: with one
        // present, the agents prefer metered API billing over the
        // subscription the user picked this provider to use.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Self.childPath(for: executable)
        // `CODEX_API_KEY` is honoured specifically by `codex exec`, and
        // the Bedrock/Vertex switches reroute Claude Code to a metered
        // backend — all of them defeat the one thing this provider is
        // for.
        for key in [
            "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
            "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX",
            "OPENAI_API_KEY", "CODEX_API_KEY",
        ] {
            env.removeValue(forKey: key)
        }
        process.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Collect output through readability handlers rather than a
        // blocking `readDataToEndOfFile`: if the agent spawns a helper
        // that inherits the pipe, EOF may never arrive, and a blocked
        // read inside `withCheckedContinuation` can never be cancelled —
        // `run()` would hang forever.
        let sink = OutputSink()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                sink.markOutEOF()
            } else {
                sink.appendOut(data)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                sink.markErrEOF()
            } else {
                sink.appendErr(data)
            }
        }

        do {
            try process.run()
        } catch {
            throw SummaryProviderError.modelUnavailable(
                provider: agent.displayName,
                reason: error.localizedDescription
            )
        }

        // Write the prompt on a background queue and close stdin so the
        // agent knows the input is complete. On its own queue because a
        // prompt bigger than the pipe buffer (a long meeting always is)
        // would otherwise deadlock — we'd block writing while the agent
        // blocks on output nobody is draining. `try?`: the throwing
        // variant turns a dead reader into an error instead of an
        // uncatchable ObjC exception.
        let promptData = Data(prompt.utf8)
        DispatchQueue.global(qos: .userInitiated).async {
            try? stdinPipe.fileHandleForWriting.write(contentsOf: promptData)
            try? stdinPipe.fileHandleForWriting.close()
        }

        let outcome = await Self.wait(for: process, timeout: Self.timeout)

        // Wait for the handlers to report EOF rather than sleeping a
        // fixed interval and hoping: a guessed drain silently truncates
        // the tail of the JSON, which surfaces as a parse failure. Still
        // bounded — if a grandchild holds the pipe open, EOF never
        // comes and we take what we have.
        let drainDeadline = Date().addingTimeInterval(1.5)
        while !sink.sawBothEOF, Date() < drainDeadline {
            do { try await Task.sleep(for: .milliseconds(40)) } catch { break }
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        let err = sink.errorText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch outcome {
        case .cancelled:
            throw CancellationError()
        case .timedOut:
            log.error("\(agent.displayName, privacy: .public) hit the \(Int(Self.timeout), privacy: .public)s limit — killed")
            throw SummaryProviderError.modelUnavailable(
                provider: agent.displayName,
                reason: String(localized: "The agent didn’t finish within 3 minutes and was stopped. Try again, or pick another provider for long meetings.")
            )
        case .exited(let status):
            guard status == 0 else {
                // WHICH stream carries the reason differs by agent, and
                // getting this wrong makes the most common first-run
                // failure undiagnosable. Claude Code prints "Not logged
                // in · Please run /login" to STDOUT and exits 1 with an
                // empty stderr; Codex streams its whole progress log to
                // stderr, so the failure is at the END, not the start.
                let stdoutText = sink.outputText.trimmingCharacters(in: .whitespacesAndNewlines)
                let detail = err.isEmpty ? stdoutText : String(err.suffix(300))
                log.error("\(agent.displayName, privacy: .public) exited \(status, privacy: .public): \(detail, privacy: .private)")
                throw SummaryProviderError.modelUnavailable(
                    provider: agent.displayName,
                    reason: detail.isEmpty
                        ? String(localized: "The agent exited without output. Check that you’re signed in — run it once in Terminal.")
                        : String(detail.suffix(300))
                )
            }
        }

        if agent.readsAnswerFromFile,
           let fileText = try? String(contentsOf: answerFile, encoding: .utf8),
           !fileText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return fileText
        }
        return sink.outputText
    }

    private enum RunOutcome {
        case exited(Int32)
        case timedOut
        case cancelled
    }

    /// Bounded wait that also honours task cancellation. Kills the agent
    /// in both the timeout and the cancel case: an abandoned CLI keeps
    /// burning the user's subscription quota.
    ///
    /// `Task.sleep` (throwing) rather than `try?` — a cancelled `try?`
    /// sleep returns instantly, turning this into a tight spin that pegs
    /// a core for the rest of the timeout. That matters because callers
    /// like `TranscriptPolisher` cancel on their own, much shorter,
    /// deadlines.
    private static func wait(for process: Process, timeout: TimeInterval) async -> RunOutcome {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Task.isCancelled {
                await kill(process)
                return .cancelled
            }
            if Date() >= deadline {
                await kill(process)
                return .timedOut
            }
            do {
                try await Task.sleep(for: .milliseconds(120))
            } catch {
                await kill(process)
                return .cancelled
            }
        }
        return .exited(process.terminationStatus)
    }

    /// SIGTERM, then SIGKILL if it's still alive. `Process.terminate`
    /// alone can leave a node runtime running.
    ///
    /// `async` with `Task.sleep`, NOT a `usleep` spin: under this
    /// target's approachable-concurrency setting a `nonisolated async`
    /// function inherits the caller's isolation, and the caller here is
    /// ultimately `@MainActor` — a blocking grace period would freeze
    /// the UI for a second on every timeout or cancel. A cancelled sleep
    /// throws, and there the right answer is to stop being polite and
    /// SIGKILL immediately.
    private static func kill(_ process: Process) async {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(1.0)
        while process.isRunning, Date() < deadline {
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                break
            }
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }

    /// One-shot `signal(SIGPIPE, SIG_IGN)`. A `static let` runs exactly
    /// once, lazily, the first time we're about to write to a pipe.
    private static let ignoreSIGPIPEOnce: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()

    // MARK: - Response parsing

    /// The agents wrap the answer in whatever prose they feel like, so
    /// `CloudSummaryDTO.decode` (which already tolerates fenced blocks
    /// and surrounding text — every cloud provider needs that) does the
    /// work.
    private func parse(_ text: String) throws -> MeetingSummary {
        do {
            return try CloudSummaryDTO.decode(from: text).toMeetingSummary()
        } catch {
            throw SummaryProviderError.parseFailed(
                provider: agent.displayName,
                message: error.localizedDescription
            )
        }
    }
}

/// Thread-safe accumulator for the child's stdout/stderr. The readability
/// handlers fire on an arbitrary queue, so the buffers need a lock.
private final class OutputSink: @unchecked Sendable {
    /// Codex streams a progress log for the whole run; without a cap a
    /// three-minute summary would buffer it all for the sake of the last
    /// few hundred characters we actually use.
    private static let maxBytes = 256 * 1024

    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private var outEOF = false
    private var errEOF = false

    func appendOut(_ data: Data) {
        lock.lock()
        out.append(data)
        if out.count > Self.maxBytes { out.removeFirst(out.count - Self.maxBytes) }
        lock.unlock()
    }

    func appendErr(_ data: Data) {
        lock.lock()
        err.append(data)
        if err.count > Self.maxBytes { err.removeFirst(err.count - Self.maxBytes) }
        lock.unlock()
    }

    func markOutEOF() { lock.lock(); outEOF = true; lock.unlock() }
    func markErrEOF() { lock.lock(); errEOF = true; lock.unlock() }

    var sawBothEOF: Bool {
        lock.lock(); defer { lock.unlock() }
        return outEOF && errEOF
    }

    var outputText: String {
        lock.lock(); defer { lock.unlock() }
        return String(data: out, encoding: .utf8) ?? ""
    }

    var errorText: String {
        lock.lock(); defer { lock.unlock() }
        return String(data: err, encoding: .utf8) ?? ""
    }
}
