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

    init(settings: AppSettings, localeIdentifier: String = "auto") {
        self.settings = settings
        self.localeIdentifier = localeIdentifier
        self.recorder = AudioRecorder()
        self.systemAudio = SystemAudioCapture()
        self.micTranscriber = Transcriber(localeIdentifier: localeIdentifier, source: .microphone)
        self.systemTranscriber = Transcriber(localeIdentifier: localeIdentifier, source: .systemAudio)
        self.summarizer = Summarizer.shared
        self.screenshots = ScreenshotCapture()

        // Preload the Whisper + diarization models so the first
        // Record click is instant and the post-process speaker
        // labelling on stop doesn't stall while the diarizer
        // downloads its CoreML weights.
        Task { await WhisperEngine.shared.ensureLoaded() }
        Task { await DiarizationEngine.shared.ensureLoaded() }
    }

    // MARK: - Lifecycle

    /// Convenience for global hotkey / auto-start triggers: start if
    /// idle/finished/failed, stop if recording, no-op otherwise.
    /// Transitional states (preparing/stopping/summarizing) are
    /// intentionally ignored so a hammered hotkey can't interrupt
    /// in-flight work.
    func toggleByHotkey() async {
        switch status {
        case .idle, .finished, .failed:
            await start()
        case .recording:
            await stop()
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
            try recorder.start(archiveURL: micArchive)
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
    }

    func stop() async {
        guard status == .recording else { return }
        status = .stopping

        recorder.stop()
        await systemAudio.stop()
        screenshots.stop()

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

    /// Two-letter ISO code derived from `localeIdentifier`. Passed to
    /// the summary provider so cloud LLMs answer in the same language
    /// as the transcript. `nil` for auto-detect.
    private var localeHintForSummary: String? {
        let prefix = localeIdentifier
            .split(separator: "-")
            .first
            .map(String.init)?
            .lowercased()
        if prefix == nil || prefix == "auto" { return nil }
        return prefix
    }

    // MARK: - Internals

    private func makeSessionDirectory() throws -> URL {
        let fm = FileManager.default
        let base = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime]
        let safeStamp = stamp.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let dir = base.appendingPathComponent("Daisy/Sessions/\(safeStamp)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
