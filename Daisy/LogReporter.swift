//
//  LogReporter.swift
//  Daisy
//
//  Help → "Send Log Report…": collects the last 24 h of Daisy's
//  os.log output (`/usr/bin/log show`, our subsystem only) plus an
//  environment header (app/macOS versions, permission states, the
//  handful of settings that change audio/ML behaviour), writes it to
//  a temp file and opens a pre-addressed Mail compose window with the
//  file attached. The user reads the report and presses Send
//  themselves — nothing leaves the Mac without an explicit, visible
//  action, consistent with "nothing leaves your Mac".
//
//  Why `log show` and not OSLogStore: OSLogStore's process scope only
//  covers the CURRENT launch, while tester reports are usually about
//  a session that ended (or a copy that crashed) earlier today.
//  `log show` reads the persisted store across launches. Trade-off:
//  info/debug lines are best-effort (the in-memory window rotates),
//  errors/faults are always there. Anything marked privacy-private
//  comes out as `<private>` — the report is privacy-safe by
//  construction.
//

import AppKit
import Foundation

@MainActor
enum LogReporter {
    /// Where tester reports go. Single hard-coded recipient on
    /// purpose — this is a built-in feedback channel, not a generic
    /// share sheet.
    private static let recipient = "essazanov@pm.me"
    /// Cap the attachment at ~5 MB — `log show --info --debug` over a
    /// chatty day can balloon, and mail providers bounce huge mails.
    /// We keep the TAIL (most recent lines) when trimming.
    /// `nonisolated`: read from the off-main log-collection closure;
    /// immutable Int, so opting out of the enum's MainActor isolation
    /// is safe.
    nonisolated private static let maxLogBytes = 5_000_000

    /// Collect → write temp file → open Mail compose. Toasts cover
    /// the slow parts and the no-Mail-account fallback.
    static func sendReport(settings: AppSettings) {
        ToastCenter.shared.show("Collecting today's logs…", style: .info, duration: .seconds(3))
        Task {
            let logText = await collectLogs()
            let report = header(settings: settings) + "\n" + logText
            let dateStamp = ISO8601DateFormatter.daisyDayStamp.string(from: Date())
            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("Daisy-log-report-\(dateStamp).txt")
            do {
                try report.write(to: fileURL, atomically: true, encoding: .utf8)
            } catch {
                ToastCenter.shared.show("Couldn't write the log report: \(error.localizedDescription)", style: .error)
                return
            }

            let subject = "Daisy log report — \(appVersionString) — \(dateStamp)"
            let body = """
            Daisy log report (last 24 h) attached.

            What happened / what I expected:
            \u{2014}

            """
            let service = NSSharingService(named: .composeEmail)
            service?.recipients = [recipient]
            service?.subject = subject
            let items: [Any] = [body, fileURL]
            if let service, service.canPerform(withItems: items) {
                service.perform(withItems: items)
                ToastCenter.shared.show("Report ready in Mail — just press Send.", style: .info)
            } else {
                // No Mail.app account configured (Gmail-in-browser
                // users). Reveal the file so it can be sent manually.
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                ToastCenter.shared.show("Mail isn't set up — report saved; send the file to \(recipient).", style: .warning, duration: .seconds(8))
            }
        }
    }

    // MARK: - Pieces

    /// `log show --last 24h` for our subsystem, off the main actor.
    /// Daisy is non-sandboxed, so spawning /usr/bin/log is fine.
    nonisolated private static func collectLogs() async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
                process.arguments = [
                    "show", "--last", "24h", "--info", "--debug",
                    "--predicate", "subsystem == \"app.essazanov.Daisy\"",
                    "--style", "compact",
                ]
                let out = Pipe()
                process.standardOutput = out
                process.standardError = Pipe()
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: "(log show failed to launch: \(error.localizedDescription))")
                    return
                }
                // Read BEFORE waitUntilExit — `log show` output easily
                // exceeds the 64 KB pipe buffer, and waiting first
                // deadlocks: the child blocks on a full pipe, we block
                // on the child.
                let data = out.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                var text = String(data: data, encoding: .utf8) ?? "(log output was not valid UTF-8)"
                if text.utf8.count > maxLogBytes {
                    // Keep the most recent tail — that's where the
                    // session being reported on lives.
                    text = "(trimmed to the most recent \(maxLogBytes / 1_000_000) MB)\n"
                        + String(decoding: Array(text.utf8.suffix(maxLogBytes)), as: UTF8.self)
                }
                continuation.resume(returning: text.isEmpty ? "(no log entries in the last 24 h)" : text)
            }
        }
    }

    /// Environment block that makes a report actionable without a
    /// follow-up email: versions, permissions, the settings that
    /// change audio/ML behaviour. No transcript content, no titles.
    private static func header(settings: AppSettings) -> String {
        let permissions = SystemPermissions.shared
        permissions.refresh()
        return """
        ── Daisy log report ─────────────────────────────
        Generated:  \(Date().formatted(date: .abbreviated, time: .standard))
        App:        \(appVersionString)
        macOS:      \(ProcessInfo.processInfo.operatingSystemVersionString)
        Permissions: mic=\(label(permissions.microphone)) screenRec=\(label(permissions.screenRecording)) accessibility=\(label(permissions.accessibility)) calendar=\(label(permissions.calendar)) notifications=\(label(permissions.notifications))
        Audio:      captureSystemAudio=\(settings.captureSystemAudio) liveTier=\(settings.liveTranscriptionTier) dictationEngine=\(settings.dictationEngine.rawValue) nemotronLivePreview=\(settings.dictationUseNemotronLive)
        Route:      \(AudioInputDevices.routeDiagnostics(selectedMicUID: settings.selectedMicDeviceUID))
        Auto-stop:  fromCalendar=\(settings.autoStopFromCalendar) graceSec=\(settings.autoStopGraceSec) promptMode=\(settings.autoStopPromptMode) notifyOnStop=\(settings.notifyOnAutoStop)
        Updates:    \(updaterLine())
        ─────────────────────────────────────────────────
        """
    }

    /// Sparkle updater state — the single most-asked "why didn't it
    /// update?" follow-up, surfaced so the answer is in the report
    /// itself: whether automatic checks are on, when the last one ran,
    /// whether the user opted into the beta channel, and the feed URL
    /// the app is actually pointed at. Reads `SparkleUpdater.shared`
    /// (real impl or the no-Sparkle stub — both expose these four).
    private static func updaterLine() -> String {
        let u = SparkleUpdater.shared
        let last = u.lastUpdateCheckDate.map {
            $0.formatted(date: .abbreviated, time: .shortened)
        } ?? "never"
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? "?"
        return "autoCheck=\(u.automaticallyChecksForUpdates) betaChannel=\(u.receiveBetaUpdates) lastCheck=\(last) canCheck=\(u.canCheckForUpdates) feed=\(feed)"
    }

    private static var appVersionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private static func label(_ status: SystemPermissions.Status) -> String {
        switch status {
        case .notDetermined: return "notAsked"
        case .granted:       return "granted"
        case .denied:        return "denied"
        case .restricted:    return "restricted"
        case .insufficient:  return "writeOnly"
        }
    }
}

private extension ISO8601DateFormatter {
    /// `2026-06-12` — filename-safe day stamp.
    static let daisyDayStamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter
    }()
}
