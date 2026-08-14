//
//  AgentCLISummarizer.swift
//  Daisy
//
//  Summaries through the Codex CLI the user already has signed in. No
//  API key: Codex authenticates with the user's own ChatGPT
//  subscription, and the request counts against that plan's limits.
//
//  WHY THERE IS NO CLAUDE CODE OPTION HERE, AND WHY IT MUST NOT BE
//  ADDED BACK. The first version of this file drove `claude -p` too.
//  That is not permitted. Anthropic's Claude Code legal page is
//  explicit: OAuth authentication "is intended exclusively ... to
//  support ordinary use of Claude Code and other native Anthropic
//  applications", and "Anthropic does not permit third-party developers
//  to offer Claude.ai login or to route requests through Free, Pro, or
//  Max plan credentials on behalf of their users" — adding that
//  "Anthropic reserves the right to take measures to enforce these
//  restrictions and may do so without prior notice."
//  (https://code.claude.com/docs/en/legal-and-compliance)
//
//  Daisy is a third-party product, publicly distributed. Shelling out to
//  a CLI the user installed themselves does not change what the request
//  IS: Daisy routing a summary through that user's Pro/Max credentials.
//  For Claude the supported routes are an API key (which Daisy already
//  offers as its own provider), a local model, or a written agreement
//  with Anthropic. If someone wants Claude-without-a-key later, the
//  honest shape is "open this transcript in Claude" — prepare the
//  prompt, hand it over, let the user paste the answer back — not an
//  automated round trip on subscription credentials.
//
//  WHY A SUBPROCESS AND NOT MCP. The elegant version of this is MCP
//  sampling: Daisy's MCP server asks the connected client (Claude
//  Desktop) to run the completion on the user's subscription. The
//  protocol has `sampling/createMessage` for exactly this — but Claude
//  Desktop has never implemented sampling, so the call has nobody to
//  answer it (and for Claude it would be barred anyway, per above).
//  Codex ships a documented non-interactive mode. So: a subprocess. (Daisy is not sandboxed — see Daisy.entitlements —
//  so it can spawn one; `MCPSummarizer` stayed HTTP-only for that
//  reason. No extra entitlement is needed to exec a separate binary.)
//
//  FIVE THINGS THIS FILE IS CAREFUL ABOUT.
//
//  1. BILLING IS NOT GUARANTEED TO BE FREE, and Daisy must never imply
//     it is. Headless agent runs have open reports of billing as
//     metered API usage when the account also has API access — one user
//     reported four figures in two days. The settings copy says to check
//     usage after the first run. We do not promise "free", and we record
//     nothing to TokenLedger because the agent reports no usage we can
//     price.
//
//  2. THIS IS AN AGENT, NOT A MODEL. Left alone, Codex can read files
//     and run commands, so every run happens in an empty temporary
//     directory with tools disabled — WHEN the installed version has a
//     flag for that (see point 5). Containment is not total either way:
//     HOME is inherited, because that's where the CLI keeps the
//     credentials this whole feature depends on, so user-scope config
//     still loads.
//
//  3. THE TRANSCRIPT LEAVES THE MAC. It goes to OpenAI under the user's
//     own account. No worse than the API-key
//     providers, but not local — `privacyTag` says so plainly. The
//     request being relayed by an app on the user's own machine must not
//     read as "stays on my Mac".
//
//  4. A GUI APP'S ENVIRONMENT IS NOT A TERMINAL'S. Launched from Finder,
//     Daisy inherits `PATH=/usr/bin:/bin:/usr/sbin:/sbin` — no Homebrew,
//     no `~/.local/bin`. A CLI installed through a package manager can be
//     a shim that execs its own runtime, so finding the shim isn't
//     enough: the CHILD needs a PATH that can find that runtime, or it
//     dies with exit 127. That is the single likeliest way this feature
//     would "work in Terminal, do nothing in Daisy".
//
//  5. WE ASK THE BINARY WHAT IT SUPPORTS INSTEAD OF GUESSING. Flag names
//     here are not hardcoded from documentation — the first run reads the
//     installed CLI's `--help` and every optional flag is used only if it
//     appears there. This is not neatness: an unsupported flag makes the
//     CLI exit with a usage error, so guessing turns a version mismatch
//     into a 100%-failure feature. Two of the flags in the first draft of
//     this file WERE wrong, taken from docs that didn't match the shipped
//     binaries. The probe is cached per binary path for the process
//     lifetime, and a failed probe degrades to the smallest command line
//     that can work rather than to nothing.
//

import Darwin
import Foundation
import os

/// Which agent CLI to drive. A single case today (see the header for why
/// Claude Code isn't one of them) but kept as an enum: the settings key
/// already persists it, and the next permitted agent should be an added
/// case rather than a rewrite.
enum AgentCLIKind: String, Codable, CaseIterable, Sendable {
    case codex

    var displayName: String {
        switch self {
        case .codex: return String(localized: "Codex")
        }
    }

    /// Executable name as found on `PATH`.
    var executableName: String {
        switch self {
        case .codex: return "codex"
        }
    }

    /// Where each installer puts the binary. Checked in order before we
    /// fall back to asking a login shell.
    var likelyPaths: [String] {
        let home = NSHomeDirectory()
        switch self {
        case .codex:
            return [
                "\(home)/.local/bin/codex",
                "/opt/homebrew/bin/codex",
                "/usr/local/bin/codex",
            ]
        }
    }

    /// The subcommand that runs one non-interactive completion, if the
    /// CLI has one.
    var subcommand: String? {
        switch self {
        case .codex: return "exec"
        }
    }

    /// Arguments built from what the INSTALLED binary says it supports,
    /// rather than from flag names hardcoded here.
    ///
    /// Every optional flag is gated on `help.has(...)`. The point is not
    /// tidiness — it's that this file integrates with someone else's CLI
    /// across versions we can't see, and a flag that doesn't exist makes
    /// the whole run exit with a usage error. Guessing gets the feature a
    /// 100%-failure mode; asking gets it a graceful one. (Two flags were
    /// already wrong when they were guessed from documentation.)
    ///
    /// What each optional flag buys, in the order we care:
    ///  • tool restriction — this is a summarizer, not a file-read
    ///    primitive. If the flag is missing we still run, and say so in
    ///    the log rather than pretending the agent is contained.
    ///  • `--skip-git-repo-check` — Codex refuses to start outside a Git
    ///    repo, and our scratch dir is a bare temp folder.
    ///  • `-o/--output-last-message` — writes just the final answer to a
    ///    file, keeping us off a progress log.
    ///  • sandbox / output format — nice to have, not load-bearing.
    func arguments(lastMessageFile: URL, help: AgentCLIHelp) -> [String] {
        var args: [String] = []
        if let subcommand { args.append(subcommand) }

        switch self {
        case .codex:
            if help.has("--skip-git-repo-check") {
                args.append("--skip-git-repo-check")
            }
            if help.has("--sandbox") {
                args += ["--sandbox", "read-only"]
            }
            if help.has("--output-last-message") {
                args += ["--output-last-message", lastMessageFile.path]
            }
            // Positional `-` = read the prompt from stdin.
            args.append("-")
        }
        return args
    }

    /// Whether the answer will be in `lastMessageFile` — only when the
    /// installed binary actually accepted the flag that writes it.
    func readsAnswerFromFile(help: AgentCLIHelp) -> Bool {
        help.has("--output-last-message")
    }

    /// True when we could NOT restrict the agent's tools on this
    /// install. Not fatal, but the caller logs it: an agent with tools
    /// is a bigger thing than the user asked for.
    func toolsUnrestricted(help: AgentCLIHelp) -> Bool {
        switch self {
        case .codex: return !help.has("--sandbox")
        }
    }
}

/// What the installed binary's `--help` says it accepts.
///
/// Deliberately dumb: a substring match over the help text. Parsing
/// option grammars properly would be a project, and the question we ask
/// is narrow — "does the literal string `--skip-git-repo-check` appear
/// in this binary's help?" — where a substring is exactly right.
struct AgentCLIHelp: Sendable {
    private let text: String

    init(text: String) { self.text = text }

    /// Empty help (the probe failed) reports every flag as ABSENT, so we
    /// fall back to the smallest command line that can work. Better a
    /// summary with tools left on than a usage error and no summary.
    static let unknown = AgentCLIHelp(text: "")

    func has(_ flag: String) -> Bool {
        guard !text.isEmpty else { return false }
        return text.contains(flag)
    }

    var isEmpty: Bool { text.isEmpty }
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

    // MARK: - Capability probe

    /// `--help` output per (binary path + subcommand), cached for the
    /// process lifetime. The probe is a subprocess; running it before
    /// every summary would add a spawn to each one for an answer that
    /// only changes when the user upgrades the CLI.
    private static let helpCache = HelpCache()

    /// Ask the installed binary what it supports. Bounded and
    /// failure-tolerant: on any error we return `.unknown`, which makes
    /// every optional flag report absent and the caller falls back to the
    /// minimal command line.
    private static func probeHelp(executable: String, subcommand: String?) async -> AgentCLIHelp {
        let key = "\(executable)|\(subcommand ?? "")"
        if let cached = helpCache.value(for: key) { return cached }

        let help: AgentCLIHelp = await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = (subcommand.map { [$0] } ?? []) + ["--help"]
            process.currentDirectoryURL = FileManager.default.temporaryDirectory
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = childPath(for: executable)
            process.environment = env

            let pipe = Pipe()
            // Some CLIs print help to stderr; take both so a tool that
            // does isn't misread as having no options at all.
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            do { try process.run() } catch { return .unknown }

            // Watchdog BEFORE the read, not after: `readDataToEndOfFile`
            // blocks until the pipe closes, so a `--help` that hangs
            // would hang this read forever and a deadline checked
            // afterwards would never be reached.
            let deadline = Date().addingTimeInterval(shellProbeTimeout)
            Thread.detachNewThread {
                while process.isRunning, Date() < deadline { usleep(50_000) }
                if process.isRunning { process.terminate() }
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
                return .unknown
            }
            return AgentCLIHelp(text: text)
        }.value

        if !help.isEmpty { helpCache.store(help, for: key) }
        return help
    }

    /// Tiny lock-guarded cache. A `final class` because the summarizer is
    /// a struct recreated per call — the cache has to outlive it.
    private final class HelpCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: AgentCLIHelp] = [:]

        func value(for key: String) -> AgentCLIHelp? {
            lock.lock(); defer { lock.unlock() }
            return entries[key]
        }

        func store(_ help: AgentCLIHelp, for key: String) {
            lock.lock(); entries[key] = help; lock.unlock()
        }
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

        // Ask the installed binary what it accepts before building the
        // command line — see `arguments(lastMessageFile:help:)`.
        let help = await Self.probeHelp(executable: executable, subcommand: agent.subcommand)
        if help.isEmpty {
            log.warning("\(agent.displayName, privacy: .public): --help probe returned nothing — using the minimal command line")
        }
        if agent.toolsUnrestricted(help: help) {
            log.warning("\(agent.displayName, privacy: .public): this version exposes no flag to restrict tools — the agent runs with its defaults")
        }

        let output = try await run(executable: executable, prompt: prompt, help: help)
        return try parse(output)
    }

    /// Spawn the agent, write the prompt to stdin, read the answer.
    ///
    /// Runs in an EMPTY temporary directory: these CLIs treat the working
    /// directory as their project context, and pointing one at the user's
    /// home would hand a summarizer a filesystem.
    private func run(executable: String, prompt: String, help: AgentCLIHelp) async throws -> String {
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
        process.arguments = agent.arguments(lastMessageFile: answerFile, help: help)
        process.currentDirectoryURL = scratch

        // Inherit the environment (HOME is where the CLI keeps its
        // credentials) but fix PATH, and strip API keys: with one
        // present, the agents prefer metered API billing over the
        // subscription the user picked this provider to use.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Self.childPath(for: executable)
        // `CODEX_API_KEY` is honoured specifically by `codex exec`, and
        // `OPENAI_API_KEY` flips Codex to metered API billing — both
        // defeat the one thing this provider is for.
        for key in ["OPENAI_API_KEY", "CODEX_API_KEY"] {
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

        if agent.readsAnswerFromFile(help: help),
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
