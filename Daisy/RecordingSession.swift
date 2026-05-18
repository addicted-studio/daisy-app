//
//  RecordingSession.swift
//  Daisy
//
//  Ties together microphone capture, optional system audio loopback,
//  Whisper transcription for each, periodic screenshots, and Apple
//  Intelligence summarization into a single observable session.
//

import Foundation
import AVFoundation
import Observation
import os

@Observable
@MainActor
final class RecordingSession {
    enum Status: Equatable {
        case idle
        case preparing
        case recording
        /// Soft pause: audio capture stopped and live transcription
        /// halted, but the session is preserved. On `resume()` we
        /// reopen the capture pipelines and keep appending to the
        /// same audio archive + transcript. From `paused` you can
        /// either `resume()` (back to .recording) or `stop()`
        /// (full finalize, summary, etc.).
        case paused
        case stopping
        case summarizing
        case finished
        case failed(String)
    }

    // MARK: - Observable

    private(set) var status: Status = .idle
    var title: String = ""
    var localeIdentifier: String {
        didSet {
            micTranscriber.localeIdentifier = localeIdentifier
            systemTranscriber.localeIdentifier = localeIdentifier
        }
    }
    private(set) var sessionDirectory: URL?
    private(set) var micArchiveURL: URL?
    private(set) var systemArchiveURL: URL?
    private(set) var startedAt: Date?

    /// When the recording was triggered by a calendar event, this
    /// holds the meeting metadata so the transcript markdown
    /// frontmatter can persist the binding. `nil` means a manual
    /// (hotkey / button) start.
    private(set) var boundMeeting: DaisyMeeting?

    /// Folder this recording will be filed into. Defaults to .inbox;
    /// the user can change it from the Home toolbar before pressing
    /// Start, and from SessionDetailView after the fact (which
    /// rewrites the transcript frontmatter on disk).
    var folder: SessionFolder = .inbox

    // Phase 2 modules — exposed so the UI can read state.
    let summarizer: Summarizer
    let screenshots: ScreenshotCapture
    let micTranscriber: Transcriber
    let systemTranscriber: Transcriber
    /// Watches recorder.levelDB during recording and flips
    /// `questionVisible` after ~3 min of continuous quiet so the
    /// floating widget can pop an "Are we done?" callout. The
    /// session owns it (matches start/pause/resume/stop lifecycle).
    /// `var` (not `let`) only so the init can assign a `self`-aware
    /// monitor after the rest of the stored state is up.
    private(set) var silenceMonitor: SilenceMonitor!

    // Re-exported recorder state.
    var elapsed: TimeInterval { recorder.elapsed }
    var levelDB: Float { recorder.levelDB }
    /// Live audio spectrum (8 bands, 0…1) used by the floating Daisy
    /// widget to animate its petals. Forwarded from the mic recorder.
    var spectrumBands: [Float] { recorder.spectrumBands }

    /// Merged transcript across mic + system, sorted by absolute start time.
    var segments: [TranscriptSegment] {
        (micTranscriber.segments + systemTranscriber.segments)
            .sorted(by: { $0.startedAt < $1.startedAt })
    }

    // MARK: - Children

    private let settings: AppSettings
    private let recorder: AudioRecorder
    private let systemAudio: SystemAudioCapture
    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "Session")

    /// Security-scoped access ticket for the user-picked sessions
    /// folder, if one is configured. Acquired at start, released at
    /// stop/reset. Sandbox apps lose access to user-picked URLs once
    /// the matching `stopAccessing` runs, so keeping the ticket
    /// alive for the whole recording is required for the audio
    /// engine's writes to land.
    private var sessionsFolderTicket: SessionsFolder.AccessTicket?

    /// Schedule that fires the actual Stop & save at calendar end +
    /// grace. Lifecycle owned by start/stop/reset.
    private var autoStopTimer: Timer?
    /// Schedule that fires 30s before `autoStopTimer` to give the
    /// user a Cancel-able warning toast.
    private var autoStopWarningTimer: Timer?
    /// Set true when the user clicks "Keep going" on the warning
    /// toast — suppresses any further auto-stop attempts in this
    /// session (no point pestering them every 30s).
    private var autoStopSuppressed: Bool = false

    init(settings: AppSettings, localeIdentifier: String = "auto") {
        self.settings = settings
        self.localeIdentifier = localeIdentifier
        self.recorder = AudioRecorder()
        self.systemAudio = SystemAudioCapture()
        self.micTranscriber = Transcriber(localeIdentifier: localeIdentifier, source: .microphone)
        self.systemTranscriber = Transcriber(localeIdentifier: localeIdentifier, source: .systemAudio)
        self.summarizer = Summarizer.shared
        self.screenshots = ScreenshotCapture()
        self.silenceMonitor = nil  // assigned below once `self` is usable
        self.silenceMonitor = SilenceMonitor(session: self)

        // Preload the Whisper + diarization models so the first
        // Record click is instant and the post-process speaker
        // labelling on stop doesn't stall while the diarizer
        // downloads its CoreML weights.
        Task { await WhisperEngine.shared.ensureLoaded() }
        Task { await DiarizationEngine.shared.ensureLoaded() }
    }

    // MARK: - Lifecycle

    /// Convenience for global hotkey / widget tap: start if idle/
    /// finished/failed, pause if recording, resume if paused.
    /// Transitional states (preparing/stopping/summarizing) are
    /// ignored so a hammered hotkey can't interrupt in-flight work.
    /// Note: the hotkey/widget never *fully stops* a session — that
    /// requires the explicit Stop & save action from the popover or
    /// the widget's right-click menu.
    func toggleByHotkey() async {
        switch status {
        case .idle, .finished, .failed:
            await start()
        case .recording:
            pause()
        case .paused:
            await resume()
        case .preparing, .stopping, .summarizing:
            return
        }
    }

    /// Start a recording that is bound to a specific calendar event.
    /// The event's title pre-fills the session title, and the
    /// transcript markdown will carry the event id in frontmatter so
    /// we can match transcripts ↔ events later. Defaults the folder
    /// to "Work" for calendar-driven recordings since most calendar
    /// meetings are work-context.
    func startFromMeeting(_ meeting: DaisyMeeting) async {
        guard status == .idle || status == .finished || isFailed else { return }
        boundMeeting = meeting
        title = meeting.title
        if folder == .inbox { folder = .work }
        await start()
    }

    func start() async {
        guard status == .idle || status == .finished || isFailed else { return }
        reset()

        if title.isEmpty {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm"
            title = "Meeting \(f.string(from: Date()))"
        }

        status = .preparing

        // Make sure Whisper is ready before we tap the mic — otherwise the
        // user sees "Recording…" with nothing happening.
        await WhisperEngine.shared.ensureLoaded()
        if case .failed(let msg) = WhisperEngine.shared.state {
            status = .failed("Whisper model failed to load: \(msg)")
            return
        }
        guard WhisperEngine.shared.isReady else {
            status = .failed("Whisper model isn't ready yet — try again in a moment.")
            return
        }

        // Session directory for archive + screenshots.
        let dir: URL?
        do { dir = try makeSessionDirectory() }
        catch {
            log.error("Session dir failed: \(error.localizedDescription, privacy: .public)")
            dir = nil
        }
        sessionDirectory = dir

        let micArchive = dir?.appendingPathComponent("microphone.caf")
        let systemArchive = dir?.appendingPathComponent("system_audio.caf")

        let nowStarted = Date()

        // Wire mic.
        let micAudio = recorder.buffers
        micTranscriber.start(consuming: micAudio, startedAt: nowStarted)
        do {
            try recorder.start(
                archiveURL: micArchive,
                preferredDeviceUID: settings.selectedMicDeviceUID
            )
        } catch {
            micTranscriber.reset()
            status = .failed(error.localizedDescription)
            return
        }
        micArchiveURL = recorder.archivedFileURL

        // Wire system audio (optional).
        if settings.captureSystemAudio {
            let systemAudioStream = systemAudio.buffers
            systemTranscriber.start(consuming: systemAudioStream, startedAt: nowStarted)
            do {
                try await systemAudio.start()
                systemArchiveURL = systemArchive
            } catch {
                log.error("System audio start failed: \(error.localizedDescription, privacy: .public)")
                // Soft-fail: keep mic-only session.
                systemTranscriber.reset()
                systemArchiveURL = nil
            }
        }

        startedAt = nowStarted
        status = .recording

        // Optional screenshots.
        if settings.screenshotsEnabled, let dir {
            let screenshotsDir = dir.appendingPathComponent("screenshots", isDirectory: true)
            await screenshots.start(intervalSec: settings.screenshotIntervalSec, into: screenshotsDir)
        }

        // Calendar-bound sessions can opt into auto-stop at end+grace.
        scheduleAutoStopIfNeeded()
        silenceMonitor.start()
    }

    // MARK: - Auto-stop (calendar-bound)

    /// Schedule the auto-stop fire + 30s warning toast if the
    /// session is bound to a calendar event AND the user has the
    /// auto-stop preference on. No-op otherwise (manual sessions are
    /// never auto-stopped).
    private func scheduleAutoStopIfNeeded() {
        cancelAutoStop()
        autoStopSuppressed = false
        guard settings.autoStopFromCalendar,
              let meeting = boundMeeting else { return }
        let now = Date()
        let fireDate = meeting.endDate.addingTimeInterval(TimeInterval(settings.autoStopGraceSec))
        guard fireDate > now else { return }

        // Warning toast fires up to 30s before the actual stop —
        // gives the user a chance to Cancel without the stop hitting
        // mid-sentence. Skip the warning if the entire grace window
        // is shorter than 30s.
        let warningLead: TimeInterval = 30
        let warningDate = fireDate.addingTimeInterval(-warningLead)
        if warningDate > now {
            autoStopWarningTimer = Timer.scheduledTimer(
                withTimeInterval: warningDate.timeIntervalSince(now),
                repeats: false
            ) { [weak self] _ in
                // Rebind to a strong `let` so the Task closure
                // captures by value — otherwise Swift 6 flags the
                // outer `weak self` var as a captured mutable
                // reference crossing concurrency boundaries.
                guard let self else { return }
                Task { @MainActor in self.fireAutoStopWarning() }
            }
        }

        autoStopTimer = Timer.scheduledTimer(
            withTimeInterval: fireDate.timeIntervalSince(now),
            repeats: false
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.performAutoStop() }
        }
        log.info("Auto-stop scheduled for \(fireDate.description, privacy: .public)")
    }

    private func cancelAutoStop() {
        autoStopTimer?.invalidate()
        autoStopWarningTimer?.invalidate()
        autoStopTimer = nil
        autoStopWarningTimer = nil
    }

    private func fireAutoStopWarning() {
        guard status == .recording || status == .paused, !autoStopSuppressed else { return }
        ToastCenter.shared.showAction(
            "Meeting ended — Daisy will stop & save in 30 seconds.",
            actionLabel: "Keep going",
            style: .warning,
            duration: .seconds(30)
        ) { [weak self] in
            guard let self else { return }
            self.cancelAutoStop()
            self.autoStopSuppressed = true
            ToastCenter.shared.show("Auto-stop cancelled for this session.", style: .info)
        }
    }

    private func performAutoStop() async {
        guard status == .recording || status == .paused, !autoStopSuppressed else { return }
        ToastCenter.shared.show("Meeting ended — stopping & saving.", style: .info, duration: .seconds(2))
        await stop()
    }

    // MARK: - Pause / Resume

    /// Soft pause. Audio capture and live transcription halt but the
    /// session state is preserved: same directory, same audio files,
    /// same accumulated segments. No celebration animation, no
    /// summary run — just a quiet hold. On `resume()` we re-open the
    /// pipelines and continue appending to the same archives.
    ///
    /// Privacy intent: clicking the floating widget mid-meeting
    /// shouldn't capture a side-conversation you didn't intend to
    /// record. Pause cuts the input stream entirely, not just the
    /// live transcript view.
    func pause() {
        guard status == .recording else { return }
        recorder.pause()
        Task { await systemAudio.pause() }
        micTranscriber.pause()
        systemTranscriber.pause()
        screenshots.stop()
        silenceMonitor.pause()
        status = .paused
        log.info("Session paused after \(self.elapsed, privacy: .public)s")
    }

    /// Resume a paused session. Audio capture restarts; the existing
    /// audio archive is appended to so the .caf file ends up as one
    /// continuous recording (gaps are simply absent, not silent).
    func resume() async {
        guard status == .paused else { return }
        do {
            try recorder.resume()
        } catch {
            log.error("Resume mic failed: \(error.localizedDescription, privacy: .public)")
            status = .failed("Couldn't resume mic capture: \(error.localizedDescription)")
            return
        }
        if settings.captureSystemAudio {
            do {
                try await systemAudio.resume()
            } catch {
                log.error("Resume system audio failed: \(error.localizedDescription, privacy: .public)")
                // Soft-fail: continue mic-only, same as during start.
            }
        }
        micTranscriber.resume()
        systemTranscriber.resume()
        if settings.screenshotsEnabled, let dir = sessionDirectory {
            let screenshotsDir = dir.appendingPathComponent("screenshots", isDirectory: true)
            await screenshots.start(intervalSec: settings.screenshotIntervalSec, into: screenshotsDir)
        }
        silenceMonitor.resume()
        status = .recording
        log.info("Session resumed")
    }

    func stop() async {
        // Full finalize — explicit user action. Allowed from both
        // .recording and .paused (the latter so the user can pause
        // first, change their mind, then commit). Anything else is a
        // no-op so transient states aren't interrupted.
        guard status == .recording || status == .paused else { return }
        if status == .paused {
            // Make sure any half-open paused pipelines are fully
            // torn down before the final transcribe.
            recorder.stop()
            await systemAudio.stop()
        }
        status = .stopping

        recorder.stop()
        await systemAudio.stop()
        screenshots.stop()
        silenceMonitor.stop()
        cancelAutoStop()
        // NOTE: do NOT release the user-folder ticket here yet —
        // we still need to write transcript.md and summary.json
        // below, both of which land inside the user-picked folder.
        // Release happens at the bottom of stop() after all writes
        // have flushed (or in the no-audio early-return path).

        // Defensive: if the user hit Stop within ~1 second of Start
        // (or any other path that didn't actually capture audio),
        // there's no point keeping the session directory around as a
        // husk. Bail out before running Whisper / writing markdown.
        let capturedAnyAudio =
            (micArchiveURL.flatMap { fileExistsNonEmpty($0) } ?? false) ||
            (systemArchiveURL.flatMap { fileExistsNonEmpty($0) } ?? false)
        if !capturedAnyAudio {
            if let dir = sessionDirectory {
                try? FileManager.default.removeItem(at: dir)
                log.info("Stop: no audio captured, removed empty session dir")
            }
            reset()
            return
        }

        // Final Whisper pass — full audio, best segmentation.
        await micTranscriber.stop()
        await systemTranscriber.stop()

        // Save markdown next to the audio archive. A failure here means
        // the user just lost their transcript on disk — surface it
        // loudly rather than swallowing.
        if let dir = sessionDirectory {
            let url = dir.appendingPathComponent("transcript.md")
            let md = MarkdownExporter.renderMarkdown(session: self)
            do {
                try md.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                log.error("Failed to write transcript.md: \(error.localizedDescription)")
                ToastCenter.shared.show(
                    "Couldn’t save transcript file. Check Console for details.",
                    style: .error
                )
            }
        }

        // Auto-summarize via the user's chosen provider (separate from STT).
        if settings.autoSummarize, case .available = summarizer.availability, !segments.isEmpty {
            status = .summarizing
            await summarizer.summarize(
                transcript: fullTranscriptText,
                title: title,
                localeHint: localeHintForSummary
            )
            if let dir = sessionDirectory, let summary = summarizer.lastSummary {
                let url = dir.appendingPathComponent("summary.json")
                do {
                    let data = try JSONEncoder().encode(summary)
                    try data.write(to: url)
                } catch {
                    log.error("Failed to write summary.json: \(error.localizedDescription)")
                    ToastCenter.shared.show(
                        "Couldn’t save summary file. Check Console for details.",
                        style: .error
                    )
                }
            }
        }

        // All writers (audio, transcript.md, summary.json) have
        // flushed by now — safe to release the security scope.
        releaseSessionsFolderTicket()
        status = .finished
    }

    /// Helper: file exists AND has non-zero size. Empty .caf files
    /// can be left behind if AVAudioEngine started its writer but
    /// never received any input frames.
    private func fileExistsNonEmpty(_ url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int else { return false }
        return size > 1024  // anything below ~1 KB is just CAF headers
    }

    func reset() {
        recorder.reset()
        micTranscriber.reset()
        systemTranscriber.reset()
        screenshots.stop()
        silenceMonitor.stop()
        cancelAutoStop()
        releaseSessionsFolderTicket()
        summarizer.clear()
        sessionDirectory = nil
        micArchiveURL = nil
        systemArchiveURL = nil
        startedAt = nil
        boundMeeting = nil
        folder = .inbox
        status = .idle
    }

    // MARK: - Computed

    var fullTranscriptText: String {
        segments
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { "[\($0.speakerLabel)] \($0.text)" }
            .joined(separator: "\n\n")
    }

    var hasContent: Bool {
        segments.contains(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    private var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }

    /// Snapshot used by Notion / Claude exporters.
    func exportData() -> MeetingExportData {
        let segmentTexts = segments
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { "[\($0.source.displayLabel)] \($0.text)" }

        // Group into ≤1500-char chunks for Notion's 2000-char block limit.
        var chunks: [String] = []
        var current = ""
        for text in segmentTexts {
            if current.count + text.count + 2 > 1500 {
                if !current.isEmpty { chunks.append(current) }
                current = text
            } else {
                current = current.isEmpty ? text : "\(current)\n\n\(text)"
            }
        }
        if !current.isEmpty { chunks.append(current) }

        return MeetingExportData(
            title: title,
            summary: summarizer.lastSummary,
            transcriptChunks: chunks,
            durationSeconds: Int(elapsed),
            locale: localeIdentifier,
            startedAt: startedAt
        )
    }

    func runSummary() async {
        guard !segments.isEmpty else { return }
        guard case .available = summarizer.availability else { return }
        let priorStatus = status
        status = .summarizing
        await summarizer.summarize(
            transcript: fullTranscriptText,
            title: title,
            localeHint: localeHintForSummary
        )
        status = priorStatus
    }

    /// Two-letter ISO code that pins the *summary* language.
    /// Precedence:
    ///   1. `settings.summaryLanguage` — explicit user override.
    ///   2. `localeIdentifier` — if it's a concrete language
    ///      (not "auto").
    ///   3. `LanguageDetector.detect(fullTranscriptText)` — sniff
    ///      the actual transcript content. Necessary because in
    ///      auto+auto we'd otherwise hand the prompt a nil hint and
    ///      Claude/GPT default to English even on a clearly-Russian
    ///      transcript.
    ///   4. `nil` — couldn't detect, let model decide.
    private var localeHintForSummary: String? {
        let override = settings.summaryLanguage
        if !override.isEmpty, override != SummaryLanguage.auto.id {
            return override
        }
        let prefix = localeIdentifier
            .split(separator: "-")
            .first
            .map(String.init)?
            .lowercased()
        if let prefix, prefix != "auto" {
            return prefix
        }
        return LanguageDetector.detect(fullTranscriptText)
    }

    // MARK: - Internals

    private func makeSessionDirectory() throws -> URL {
        // Acquire and hold the security-scoped folder for the
        // entire recording lifetime. ticket.url is either the user-
        // picked folder (Obsidian vault, ~/Documents/Meetings, …)
        // or the app's container default. Released in stop()/reset().
        guard let ticket = SessionsFolder.acquireBase() else {
            throw NSError(
                domain: "app.essazanov.Daisy",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Couldn't resolve a writable sessions folder."]
            )
        }
        self.sessionsFolderTicket = ticket

        let fm = FileManager.default
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime]
        let safeStamp = stamp.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let dir = ticket.url.appendingPathComponent("Daisy/Sessions/\(safeStamp)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Release the security-scoped folder ticket. Called from
    /// `stop()` and `reset()` so we don't hold the user's folder
    /// open after a session is finalised.
    private func releaseSessionsFolderTicket() {
        sessionsFolderTicket?.release()
        sessionsFolderTicket = nil
    }
}
