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
// NSPasteboard / Accessibility-paste live behind `DictationPaste`
// now — RecordingSession itself doesn't need AppKit.

/// Shared JSON coders configured for Daisy's `.send_failures.json`
/// sidecar (and any future per-session JSON file that wants the
/// same ergonomics — pretty-printed, deterministic key order,
/// ISO 8601 timestamps that a human can read in a terminal).
///
/// File-scope `extension` so the encoder/decoder live next to the
/// `SendFailureRecord` consumer without polluting every other JSON
/// path in the app.
nonisolated extension JSONEncoder {
    static var daisySendFailureEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

nonisolated extension JSONDecoder {
    static var daisySendFailureDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

@Observable
@MainActor
final class RecordingSession {
    /// One of three top-level modes the user can engage:
    ///
    ///   - `.meeting` — the classic Daisy flow. Mic + system audio,
    ///     LLM summary, autoSend to Notion/MCP, full session saved
    ///     to History.
    ///
    ///   - `.voiceNote` — quick personal capture. Mic only (no
    ///     system audio, no remote participants), NO LLM summary
    ///     (just the transcript), folder forced to `.notes`.
    ///     Useful for "remember this before I forget" moments.
    ///
    ///   - `.dictation` — Wispr-Flow-lite. Mic only, no summary,
    ///     transcript goes straight to the clipboard and the
    ///     session directory is deleted on stop. A toast tells the
    ///     user to ⌘V into their target app. No persistent
    ///     artifacts — the user is producing typed text, not a
    ///     transcript.
    ///
    /// Mode is set at start time via the corresponding hotkey or
    /// public toggle method. It survives across `pause()`/`resume()`
    /// (you can pause a voice note mid-record). Defaults to
    /// `.meeting` for any code path that doesn't explicitly pick.
    enum RecordingMode: String, Codable, Sendable {
        case meeting
        case voiceNote
        case dictation
    }

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
        /// **Deprecated as of 2026-05-19** — `stop()` now jumps from
        /// `.stopping` straight to `.finished` and runs summarize +
        /// autoSend in a detached background task, so the widget /
        /// panel no longer blocks for the 15-30 seconds an LLM call
        /// takes. See `summaryGenerationState` for the new lifecycle.
        /// The case is kept so existing exhaustive switches still
        /// compile; it is never assigned by normal flow.
        case summarizing
        case finished
        case failed(String)
    }

    /// Independent lifecycle for the post-Stop summary + auto-send
    /// pipeline. Decoupled from `Status` so the widget can go idle
    /// the instant `transcript.md` is on disk, while the LLM call
    /// keeps running in the background and a placeholder skeleton
    /// shows in SessionDetailView until the summary lands.
    enum SummaryGenerationState: Equatable {
        /// No active post-Stop summary task. Either none was needed
        /// (auto-summarize off, no provider, zero segments) or the
        /// previous one finished/was cancelled.
        case idle
        /// Detached task is running: summarize() in flight, then
        /// summary.json write, then autoSend.
        case generating
        /// summary.json is on disk and autoSend has completed.
        case ready
        /// Summarizer threw, autoSend failed, or the task was
        /// cancelled by a fresh `start()`. Carries a short reason
        /// for surfacing in toasts/logs.
        case failed(String)
    }

    // MARK: - Observable

    /// User-facing summary of the system-audio capture pipeline.
    /// Exposed so UI surfaces (HomeView, sidebar capsule, widget)
    /// can show whether the "other side" of the meeting is being
    /// captured — a permission denial or silent failure shouldn't
    /// leave the user discovering it after a 60-minute meeting.
    enum SystemAudioStatus: Equatable {
        case disabled               // user toggled it off in Settings
        case pending                // recording hasn't started yet
        case capturing              // SCStream is live and feeding the transcriber
        case denied                 // Screen Recording permission missing — skipped at start()
        case failed(String)         // SCStream.startCapture() threw or stopped unexpectedly
    }

    private(set) var status: Status = .idle

    /// Post-Stop summary lifecycle. Set to `.generating` the moment
    /// `stop()` spins up the detached finalize task; flips to
    /// `.ready` when summary.json is written + autoSend ran; flips
    /// to `.failed` if summarizer threw or task was cancelled by a
    /// fresh recording. Drives the SessionDetailView skeleton + the
    /// widget's amber-pulse "summary cooking" indicator.
    private(set) var summaryGenerationState: SummaryGenerationState = .idle

    /// Detached task spun up by `stop()` that handles summarize →
    /// summary.json write → autoSend, in that order. Held so a fresh
    /// `start()` / `reset()` can cancel it. Kept @ObservationIgnored
    /// because the Task reference itself isn't UI-relevant — only
    /// `summaryGenerationState` is.
    @ObservationIgnored
    private var summaryTask: Task<Void, Never>?

    /// True when the most recent `start()` skipped system audio
    /// because `CGPreflightScreenCaptureAccess()` returned false.
    /// Cleared on the next start() that successfully bootstraps the
    /// stream — so toggling Screen Recording on and starting a new
    /// recording produces the right `systemAudioStatus`.
    private var systemAudioDeniedThisSession: Bool = false
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

    /// Auto-matched speaker map produced after the final diarization
    /// pass — Daisy looks up each detected speaker's centroid
    /// embedding in `SpeakerProfileStore` and pre-fills "A" → "Alex"
    /// when a stored profile cosine-matches. Read by `MarkdownExporter`
    /// when writing transcript.md so the user opens the session and
    /// sees real names already in place; empty map for first-time
    /// recordings (no profiles yet) or mic-only sessions.
    private(set) var initialSpeakerMap: [String: String] = [:]

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

    /// Client tag for this session. Persisted to frontmatter as
    /// `daisy_client:` and used for sidebar grouping in History.
    /// Empty string == "untagged" (the default). Free-form text;
    /// `ClientSuggestion.suggest(from:)` pre-fills this when the
    /// session is bound to a calendar event with attendees from
    /// an external organization.
    var client: String = ""

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
    /// Every archived audio file the mic recorder produced for this
    /// session. Always at least `[microphone.caf]` while recording;
    /// becomes `[microphone.caf, microphone.part2.caf, …]` when a
    /// mid-session route change forced a format-rollover into a
    /// new part. Exposed for `MarkdownExporter` frontmatter +
    /// future History-pane "this session has N audio parts"
    /// affordance.
    var archivedAudioParts: [URL] { recorder.archivedParts }

    /// Merged transcript across mic + system, sorted by absolute start time.
    var segments: [TranscriptSegment] {
        (micTranscriber.segments + systemTranscriber.segments)
            .sorted(by: { $0.startedAt < $1.startedAt })
    }

    /// Derived from `SystemAudioCapture.state` + the once-per-session
    /// denial flag set when preflight rejected us at start. UI binds
    /// to this for a "Other side: capturing / off" pill so users see
    /// mid-recording whether the remote party is actually being
    /// captured.
    var systemAudioStatus: SystemAudioStatus {
        if !settings.captureSystemAudio { return .disabled }
        // Only meaningful once we're recording — before that
        // SystemAudioCapture sits in .idle which doesn't yet say
        // anything about runtime state.
        guard status == .recording || status == .paused else {
            return .pending
        }
        if systemAudioDeniedThisSession { return .denied }
        switch systemAudio.state {
        case .capturing, .starting, .paused:
            return .capturing
        case .idle, .stopped:
            return .failed(systemAudio.lastError ?? "Capture stopped unexpectedly")
        }
    }

    // MARK: - Children

    // Module-internal so `SilenceMonitor` can read
    // `silencePromptsEnabled` without us threading an extra
    // reference through its constructor.
    let settings: AppSettings
    private let recorder: AudioRecorder
    private let systemAudio: SystemAudioCapture
    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "Session")
    /// Dedicated logger for auto-stop wire-up. Separate category so
    /// support can filter Console.app to the exact flow:
    ///   `subsystem:app.essazanov.Daisy category:AutoStop`
    /// Pre-1.0.4 every early-return in `scheduleAutoStopIfNeeded()` was
    /// silent, which is why a tester with the toggle ON but a manual
    /// start (no `boundMeeting`) looked indistinguishable from a wire
    /// bug. Now each abort logs which guard tripped.
    private let autoStopLog = Logger(subsystem: "app.essazanov.Daisy", category: "AutoStop")

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

    /// Active recording mode. Persists across pause/resume but
    /// resets to `.meeting` on `reset()` — fresh sessions default
    /// to the original Daisy meeting flow unless a mode-specific
    /// hotkey set `pendingMode` first.
    private(set) var currentMode: RecordingMode = .meeting

    /// Mode the next `start()` should adopt. Set by mode-specific
    /// entry points (`toggleVoiceNoteByHotkey`, etc.) right before
    /// they call `start()`, consumed inside `start()` after
    /// `reset()`. Same pattern as `pendingBoundMeeting` —
    /// `reset()` clears the live value, the pending channel
    /// survives the wipe.
    @ObservationIgnored
    private var pendingMode: RecordingMode?

    /// Calendar-driven meeting binding that should be applied to the
    /// session AFTER `start()` runs its internal `reset()` (which
    /// otherwise nukes the binding). Set by `startFromMeeting(_:)`
    /// just before it calls `start()`; consumed inside `start()` and
    /// cleared. This is the channel that makes calendar auto-stop
    /// actually work — without it, reset() blew away `boundMeeting`
    /// between the caller setting it and `scheduleAutoStopIfNeeded()`
    /// reading it, so the auto-stop timer was never armed.
    @ObservationIgnored
    private var pendingBoundMeeting: DaisyMeeting?

    /// Folder hint applied in the same after-reset() phase as
    /// `pendingBoundMeeting`. Used by calendar starts to default
    /// the new session into Work (instead of Inbox) without leaking
    /// state through `reset()`.
    @ObservationIgnored
    private var pendingFolderHint: SessionFolder?

    init(settings: AppSettings, localeIdentifier: String? = nil) {
        self.settings = settings
        // Caller can override (used by tests), otherwise pull the
        // user's chosen default from Settings → Transcription.
        // Empty / missing falls back to "auto" — the legacy
        // behaviour. Per-session override still works via the
        // popover locale picker, which writes through
        // `session.localeIdentifier`.
        let resolved = localeIdentifier ?? settings.defaultTranscriptionLocale
        let effective = resolved.isEmpty ? "auto" : resolved
        self.localeIdentifier = effective
        self.recorder = AudioRecorder()
        self.systemAudio = SystemAudioCapture()
        self.micTranscriber = Transcriber(
            localeIdentifier: effective,
            source: .microphone,
            // Opt-in mic-side diarization — useful when remote
            // participants are heard through the user's speakers
            // (in-room playback) instead of being captured separately
            // via system-audio loopback. See AppSettings comment.
            diarize: settings.diarizeMicrophone
        )
        self.systemTranscriber = Transcriber(
            localeIdentifier: effective,
            source: .systemAudio
        )
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

        // Warm the AVAudioEngine HAL graph up front so the first
        // user-initiated record (especially dictation, where the
        // user expects instant capture) doesn't pay the cold-start
        // tax. Cheap, no TCC prompts, no recording-light.
        recorder.prewarm()

        // Probe the configured summary provider once so its status
        // (Available / Unavailable) is known before the user opens
        // Settings → Summary for the first time. Without this, the
        // first visit to that tab shows "Checking…" for ~1s before
        // resolving.
        Task { await Summarizer.shared.refreshAvailability() }

        // Listen for the auto-start banner's "Stop & save" action.
        // DaisyAppDelegate routes the macOS notification action into
        // this Foundation bus; we run the same stop() the user would
        // get from the toolbar / widget. Observer is owned by the
        // singleton's lifetime — no removal needed.
        NotificationCenter.default.addObserver(
            forName: AutoStartNotification.stopRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.status == .recording || self.status == .paused else { return }
                self.log.info("Auto-start banner Stop & save tapped — stopping session")
                await self.stop()
            }
        }
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

    /// Voice-notes — TOGGLE on tap. Single press starts a
    /// `.voiceNote` session (mic only, no system audio, no LLM
    /// summary, Notes folder); next press of the same hotkey
    /// stops it. Different from dictation (hold-to-talk) because
    /// voice notes can be longer than the user wants to keep a
    /// finger on the key — meeting yourself, dictating ideas
    /// over 5–10 min, etc.
    func toggleVoiceNoteByHotkey() async {
        switch status {
        case .idle, .finished, .failed:
            pendingMode = .voiceNote
            pendingFolderHint = .notes
            await start()
        case .recording, .paused:
            if currentMode == .voiceNote {
                await stop()
            } else {
                ToastCenter.shared.show(
                    "Daisy is already recording. Stop the current session first.",
                    style: .warning
                )
            }
        case .preparing, .stopping, .summarizing:
            return
        }
    }

    /// Dictation — push-to-record. Called on hotkey-down edge.
    /// Starts a `.dictation` session (mic only, ephemeral, no
    /// History entry). On release, the transcript is copied to
    /// the clipboard and a toast prompts ⌘V. Wispr-Flow-lite.
    func startDictationHotkey() async {
        switch status {
        case .idle, .finished, .failed:
            pendingMode = .dictation
            await start()
        case .recording, .paused:
            ToastCenter.shared.show(
                "Daisy is already recording. Stop the current session first.",
                style: .warning
            )
        case .preparing, .stopping, .summarizing:
            return
        }
    }

    /// Dictation — release. Triggers the stop() path which, when
    /// `currentMode == .dictation`, copies the final transcript
    /// to the clipboard and deletes the session directory before
    /// returning to idle.
    func stopDictationHotkey() async {
        guard currentMode == .dictation else { return }
        guard status == .recording || status == .paused else { return }
        await stop()
    }

    /// Start a recording that is bound to a specific calendar event.
    /// The event's title pre-fills the session title, the transcript
    /// markdown carries the event id in frontmatter so we can match
    /// transcripts ↔ events later, and (if `settings.autoStopFromCalendar`
    /// is on) an auto-stop timer is armed for `meeting.endDate +
    /// autoStopGraceSec`. Defaults the folder to "Work" since most
    /// calendar meetings are work-context.
    ///
    /// Handles three cases:
    ///   1. **Idle/finished/failed** — fresh start, the simple path.
    ///   2. **Already recording the SAME event** — calendar tick polls
    ///      the +30/-120 s fire window every 15 s, so re-fires happen
    ///      naturally. No-op so we don't churn title/binding.
    ///   3. **Already recording a DIFFERENT event** — the back-to-back
    ///      meeting case that produced the tester's "M2 recorded into
    ///      M1's session" bug. Stop & save M1, cancel any in-flight
    ///      summary, then start M2 fresh. Surfaces a toast so the user
    ///      knows the rotation happened.
    ///
    /// The `pendingBoundMeeting` / `pendingFolderHint` channel matters
    /// here: a naive `boundMeeting = meeting` before `await start()`
    /// silently fails, because `start()` calls `reset()` internally
    /// which sets `boundMeeting = nil` (and the field never gets
    /// repopulated before `scheduleAutoStopIfNeeded()` reads it). The
    /// pending properties are picked up AFTER reset() and applied to
    /// the fresh session, which is what actually wires up auto-stop.
    func startFromMeeting(_ meeting: DaisyMeeting) async {
        // Same event re-fired — no-op rather than stamping title/
        // binding on top of an already-running session.
        if (status == .recording || status == .paused),
           boundMeeting?.localID == meeting.localID {
            return
        }

        // Different event fired while we're still recording — auto-
        // rotate sessions. Without this branch, calendar trigger for
        // Meeting #2 silently returns and M1's session keeps running
        // with M1's bindings.
        if status == .recording || status == .paused {
            let oldTitle = self.boundMeeting?.title ?? self.title
            log.warning("Calendar fired \(meeting.title, privacy: .private) while still recording \(oldTitle, privacy: .private). Auto-rotating sessions.")
            ToastCenter.shared.show(
                "Previous meeting saved — starting new session for \(meeting.title).",
                style: .info
            )
            await stop()
        }

        // After stop() the post-Stop summary task may still be in
        // flight (status == .summarizing). Cancel it so the new
        // session's writes don't race against the old session's
        // summary.json write — transcript.md for the previous
        // meeting is already on disk; the user can re-summarize
        // from History if they need that summary.
        summaryTask?.cancel()
        summaryTask = nil

        // Bridge .summarizing → .finished so start()'s guard accepts
        // immediately rather than letting the rotation drop on the
        // floor.
        if status == .summarizing { status = .finished }

        guard status == .idle || status == .finished || isFailed else {
            log.warning("startFromMeeting aborted — unexpected state \(String(describing: self.status), privacy: .public)")
            return
        }

        // Stash for after-reset() pickup inside start(). Setting these
        // directly here would be erased by reset().
        pendingBoundMeeting = meeting
        pendingFolderHint = .work
        // Title CAN be set directly — reset() does not clear `title`,
        // and start()'s "if title.isEmpty" fallback only fires when
        // the user didn't explicitly set one.
        title = meeting.title

        await start()

        // macOS banner so the user notices Daisy just auto-started
        // their meeting (and can bail via "Stop & save" if they
        // didn't want this one tracked). Gated on the per-class
        // toggle in Settings → General → Notifications.
        if settings.notifyOnAutoStart {
            AutoStartNotification.post(meetingTitle: meeting.title)
        }
    }

    func start() async {
        // If a previous Stop's summary task is still in flight, the
        // user has explicitly asked for a NEW recording — drop the
        // old finalize. transcript.md is already on disk (synchronous
        // path in stop()), so the worst case is that summary.json
        // and any auto-send to Notion/MCP haven't landed yet for the
        // previous session; the user can fix that from History →
        // Re-summarize. Fire-and-forget cancel: we don't await the
        // task value, the new recording shouldn't wait on the LLM.
        summaryTask?.cancel()
        summaryTask = nil

        guard status == .idle || status == .finished || isFailed else { return }
        reset()

        // Apply meeting/folder/mode bindings stashed by entry-point
        // helpers (`startFromMeeting`, `toggleVoiceNoteByHotkey`,
        // `toggleDictationByHotkey`). These need to land AFTER
        // reset() — reset clears boundMeeting/folder/currentMode
        // back to defaults — otherwise `scheduleAutoStopIfNeeded`
        // sees `boundMeeting == nil`, and `finalizePostStop` runs
        // the meeting pipeline against what should have been a
        // dictation session.
        if let m = pendingBoundMeeting {
            boundMeeting = m
            pendingBoundMeeting = nil
            // Auto-suggest client tag from attendee domains. The
            // user can override in SessionDetailView; this just
            // pre-fills with a sensible guess so most meetings end
            // up tagged without any manual work.
            if client.isEmpty, let suggested = ClientSuggestion.suggest(from: m.attendeeEmails) {
                client = suggested
            }
        }
        if let hint = pendingFolderHint {
            if folder == .inbox { folder = hint }
            pendingFolderHint = nil
        }
        if let mode = pendingMode {
            currentMode = mode
            pendingMode = nil
        } else {
            currentMode = .meeting
        }

        // Voice notes auto-file into the Notes folder. Only override
        // when `folder` is still the default Inbox — if the user
        // explicitly picked another folder via UI (or a calendar
        // hint dropped them into Work / Calls), respect that.
        // Dictation sessions are ephemeral (no History entry) so
        // the folder value is irrelevant for them.
        if currentMode == .voiceNote && folder == .inbox {
            folder = .notes
        }

        // Apply mode-specific transcription locale override, falling
        // back to the meeting default. Empty string in the override
        // means "inherit". Pre-1.0.3 dictation/voice-note always used
        // `defaultTranscriptionLocale`, which auto-detected English
        // for a clearly Russian dictation if the early few seconds
        // were ambiguous — user reported "Я диктовал на русском, а
        // он перевёл на английский".
        let modeLocale: String
        switch currentMode {
        case .meeting:
            modeLocale = settings.defaultTranscriptionLocale
        case .voiceNote:
            modeLocale = settings.voiceNoteLocale.isEmpty
                ? settings.defaultTranscriptionLocale
                : settings.voiceNoteLocale
        case .dictation:
            modeLocale = settings.dictationLocale.isEmpty
                ? settings.defaultTranscriptionLocale
                : settings.dictationLocale
        }
        let effectiveLocale = modeLocale.isEmpty ? "auto" : modeLocale
        if localeIdentifier != effectiveLocale {
            localeIdentifier = effectiveLocale
        }

        if title.isEmpty {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm"
            title = "Meeting \(f.string(from: Date()))"
        }

        status = .preparing

        // Make sure Whisper is ready before we tap the mic — otherwise the
        // user sees "Recording…" with nothing happening. Each early-exit
        // path below goes through `failFast(_:)` so we don't leak the
        // sandbox ticket from `makeSessionDirectory()` or the half-
        // started transcribers — pre-1.0.3 these `return`s left
        // `sessionsFolderTicket` retained until the next start/reset.
        await WhisperEngine.shared.ensureLoaded()
        if case .failed(let msg) = WhisperEngine.shared.state {
            failFast("Whisper model failed to load: \(msg)")
            return
        }
        guard WhisperEngine.shared.isReady else {
            failFast("Whisper model isn't ready yet — try again in a moment.")
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
            failFast(error.localizedDescription)
            return
        }
        micArchiveURL = recorder.archivedFileURL

        // Wire system audio (optional).
        //
        // Two failure modes used to be silent:
        //   1. Screen Recording permission is denied — `SCStream.
        //      startCapture()` throws, we logged it, the user kept
        //      talking, only their voice ended up in the transcript.
        //   2. Permission is granted but the stream errored out
        //      mid-start (display gone, etc.) — same silent fall-
        //      through.
        // Both now produce a visible toast (the deny case includes
        // an "Open Privacy Settings" deeplink) so the user finds out
        // BEFORE the meeting, not after.
        systemAudioDeniedThisSession = false
        // Voice notes and dictation are personal-mic-only flows —
        // the user is the only voice that matters. Skip the
        // SCStream loopback entirely so we don't ask for Screen
        // Recording permission on first dictation use and don't
        // burn CPU on a 2×2 video stream we'll throw away.
        if settings.captureSystemAudio && currentMode == .meeting {
            // Preflight TCC. `CGPreflightScreenCaptureAccess()`
            // doesn't itself prompt — calling SCK without checking
            // would prompt mid-startCapture, but if the user
            // already denied once we'd skip straight to "throw".
            if !ScreenRecordingPermission.isGranted {
                systemAudioDeniedThisSession = true
                log.warning("Screen Recording permission denied — recording mic only")
                ToastCenter.shared.showAction(
                    "Couldn't capture the other side — Screen Recording permission is off. Recording your voice only.",
                    actionLabel: "Open Privacy Settings",
                    style: .warning,
                    duration: .seconds(20),
                    perform: { ScreenRecordingPermission.openSystemSettings() }
                )
            } else {
                let systemAudioStream = systemAudio.buffers
                systemTranscriber.start(consuming: systemAudioStream, startedAt: nowStarted)
                do {
                    try await systemAudio.start(archiveURL: systemArchive)
                    systemArchiveURL = systemArchive
                } catch {
                    log.error("System audio start failed: \(error.localizedDescription, privacy: .public)")
                    systemTranscriber.reset()
                    systemArchiveURL = nil
                    // Loud fail — previously swallowed in os_log.
                    // The user is about to start a meeting; they
                    // need to know the remote side won't be
                    // captured.
                    ToastCenter.shared.show(
                        "Couldn't capture the other side — recording your voice only.",
                        style: .warning
                    )
                }
            }
        }

        startedAt = nowStarted
        status = .recording
        if settings.recordingSoundsEnabled { SoundEffects.playStart() }

        // Optional screenshots.
        if settings.screenshotsEnabled, let dir {
            let screenshotsDir = dir.appendingPathComponent("screenshots", isDirectory: true)
            await screenshots.start(intervalSec: settings.screenshotIntervalSec, into: screenshotsDir)
        }

        // Manual-start fallback: if the user hit the hotkey before
        // CalendarService.tick() got to auto-start, try to match the
        // session to a currently-running meeting so auto-stop still
        // arms. No-op if `boundMeeting` is already set (auto-start
        // path).
        bindCurrentMeetingIfPossible()

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
        guard settings.autoStopFromCalendar else {
            autoStopLog.info("scheduleAutoStop: skipped — autoStopFromCalendar=false")
            return
        }
        guard let meeting = boundMeeting else {
            // Most common silent failure pre-1.0.4: user toggled the
            // pref ON but started the recording manually (hotkey /
            // widget) before the calendar tick auto-started it, so
            // boundMeeting was never wired. `start()` now tries to
            // auto-bind via `bindCurrentMeetingIfPossible()`; this
            // log captures the case where even that fallback misses.
            autoStopLog.info("scheduleAutoStop: skipped — no boundMeeting on this session (manual start without matching calendar event in fire window)")
            return
        }
        let now = Date()
        let fireDate = meeting.endDate.addingTimeInterval(TimeInterval(settings.autoStopGraceSec))
        guard fireDate > now else {
            autoStopLog.warning("scheduleAutoStop: meeting '\(meeting.title, privacy: .private)' already past its end+grace (endDate=\(meeting.endDate.description, privacy: .public), grace=\(self.settings.autoStopGraceSec, privacy: .public)s) — no timer armed")
            return
        }

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
        autoStopLog.info("Auto-stop armed for '\(meeting.title, privacy: .private)' at \(fireDate.description, privacy: .public) (in \(Int(fireDate.timeIntervalSince(now)), privacy: .public)s)")
    }

    /// Try to auto-bind a calendar meeting to the current session
    /// when the user started recording manually (hotkey/widget) but
    /// a calendar event is currently in or near its start window.
    /// Mirrors the `CalendarService.tick()` fire window — `meeting.start
    /// - 30s … meeting.end` — so any meeting we'd have auto-started is
    /// also a meeting we'll auto-bind to. Without this, the tester's
    /// hotkey-start-before-calendar-tick path produced an unbindable
    /// session and silently swallowed the auto-stop preference.
    ///
    /// Idempotent — no-op if `boundMeeting` is already set or no
    /// matching meeting exists. Called from `start()` after `reset()`
    /// has applied any explicit `pendingBoundMeeting`.
    private func bindCurrentMeetingIfPossible() {
        guard boundMeeting == nil else { return }
        guard currentMode == .meeting else { return }
        let now = Date()
        let match = CalendarService.shared.upcomingMeetings.first { meeting in
            // Window mirrors CalendarService.tick(): -120s … +30s of
            // start, AND not yet past end. Without the lower bound a
            // long-running all-day "OOO" event flagged as a meeting
            // would bind anything started in the last 8 hours — and
            // auto-stop would fire at the event's far-future end.
            let deltaToStart = meeting.startDate.timeIntervalSince(now)
            let inStartWindow = deltaToStart <= 30 && deltaToStart >= -120
            let stillRunning = meeting.endDate > now
            return inStartWindow && stillRunning
        }
        guard let meeting = match else {
            autoStopLog.info("bindCurrentMeetingIfPossible: no calendar meeting in fire window")
            return
        }
        boundMeeting = meeting
        // Only overwrite the autogenerated `"Meeting yyyy-MM-dd HH:mm"`
        // placeholder (set at line ~577), never a user-typed title.
        // hasPrefix("Meeting ") was too greedy — caught "Meeting with
        // Anna prep" and clobbered intentional user titles.
        if title.isEmpty || Self.isAutoGeneratedMeetingTitle(title) {
            title = meeting.title
        }
        if folder == .inbox { folder = .work }
        // Pre-fill client tag from attendee domain (most-frequent
        // external org). Same call site as the auto-binding in
        // start() so manual-start sessions also get the suggestion.
        if client.isEmpty, let suggested = ClientSuggestion.suggest(from: meeting.attendeeEmails) {
            client = suggested
        }
        autoStopLog.info("bindCurrentMeetingIfPossible: auto-bound to '\(meeting.title, privacy: .private)' (started \(Int(now.timeIntervalSince(meeting.startDate)), privacy: .public)s ago, ends in \(Int(meeting.endDate.timeIntervalSince(now)), privacy: .public)s)")
    }

    /// True iff `s` matches the exact `"Meeting yyyy-MM-dd HH:mm"`
    /// shape produced by `start()` when the user hasn't typed one in.
    /// Uses a precise regex rather than `hasPrefix("Meeting ")` so
    /// a user-typed title that happens to start with "Meeting " is
    /// preserved through auto-bind.
    nonisolated private static func isAutoGeneratedMeetingTitle(_ s: String) -> Bool {
        let pattern = #"^Meeting \d{4}-\d{2}-\d{2} \d{2}:\d{2}$"#
        return s.range(of: pattern, options: .regularExpression) != nil
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
        let meetingTitle = boundMeeting?.title ?? title
        await stop()
        // Banner confirms the save completed — surfaces even when
        // Daisy is in the background, which is the common case for
        // an auto-stopped session. Gated on the per-class toggle.
        if settings.notifyOnAutoStop {
            AutoStopNotification.post(meetingTitle: meetingTitle)
        }
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
        if settings.recordingSoundsEnabled { SoundEffects.playPause() }
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
        // Late-binding safety net: a user could have granted Calendar
        // access AFTER starting + pausing the session, or the meeting
        // could have appeared in the calendar mid-session via iCloud
        // sync. Re-running the bind + schedule on resume catches those
        // edge cases cheaply (no-op if boundMeeting is already set).
        bindCurrentMeetingIfPossible()
        scheduleAutoStopIfNeeded()
        status = .recording
        if settings.recordingSoundsEnabled { SoundEffects.playResume() }
        log.info("Session resumed")
    }

    func stop() async {
        // Full finalize — explicit user action. Allowed from both
        // .recording and .paused (the latter so the user can pause
        // first, change their mind, then commit). Anything else is a
        // no-op so transient states aren't interrupted.
        guard status == .recording || status == .paused else { return }
        // Stop cue fires up front — by the time the final
        // transcribe + summary finish (seconds later), the user has
        // moved on to other tasks. The audio cue confirms the
        // click "took" even if the heavy work is still running.
        if settings.recordingSoundsEnabled { SoundEffects.playStop() }
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

        // Surface the "system audio capture armed but received zero
        // frames" condition before the user navigates away from the
        // session. Most common root cause: the macOS default output
        // is a Bluetooth device — Screen Capture can't loop back BT
        // by design, so the captured stream is silent and the
        // user's `system_audio.caf` ends up 0 bytes. The 30-second
        // in-flight watchdog inside SystemAudioCapture warns once
        // per session, but it can be missed (focus mode, busy
        // meeting); this is the second-chance summary toast.
        //
        // Sessions shorter than 60 s skip the warning — there's not
        // enough signal to distinguish "user stopped intentionally"
        // from "capture broken".
        if settings.captureSystemAudio,
           currentMode == .meeting,
           elapsed > 60,
           !systemAudio.hasReceivedAudio {
            ToastCenter.shared.show(
                "System audio was empty for this session — usually Bluetooth output. Other participants weren't captured separately, so per-speaker labels in the transcript will be 'Me' only. Use built-in speakers or wired headphones for next time.",
                style: .warning,
                duration: .seconds(10)
            )
            log.warning("Session ended with empty system audio despite captureSystemAudio=on. Likely BT output.")
        }
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

        // Voice fingerprint pass — match this session's speaker
        // clusters against the persistent SpeakerProfileStore so
        // returning speakers get auto-named ("Alex" not "Remote A")
        // before the user even opens the transcript. Also writes
        // a `speakers.json` sidecar with raw centroids so when the
        // user MANUALLY renames a Remote in SessionDetailView, we
        // know which embedding to associate with the new name and
        // can persist a fresh profile.
        applySpeakerProfileMatches()

        // Dictation mode — fully ephemeral. By this point Whisper
        // has produced its final transcript; hand it to the
        // `DictationPaste` coordinator which:
        //   1. Snapshots the current clipboard
        //   2. Writes the transcript
        //   3. Tries to auto-paste via Accessibility-permitted ⌘V
        //   4. Schedules a 10 s restore so the user's previous
        //      clipboard contents come back if they haven't
        //      copied anything else.
        // Then nuke the session directory + reset. No transcript.md,
        // no summary.json, no History entry, no autoSend.
        if currentMode == .dictation {
            let transcriptText = fullTranscriptText
                .trimmingCharacters(in: .whitespacesAndNewlines)
            DictationPaste.shared.handle(transcript: transcriptText)
            if let dir = sessionDirectory {
                try? FileManager.default.removeItem(at: dir)
            }
            releaseSessionsFolderTicket()
            reset()
            return
        }

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

        // ── Granola-style: status → .finished BEFORE summary ──────────
        //
        // Everything user-visible the recording lifecycle needs is on
        // disk now: audio, transcript.md, speakers.json. The widget /
        // panel can go idle, the user can start a new recording. The
        // LLM call (15-30 s) and downstream auto-send happen in a
        // detached task below and report progress through
        // `summaryGenerationState`, not through `status`.
        // LLM summary only runs for full `.meeting` mode. Voice
        // notes are bare transcript + audio (kept in History under
        // Notes folder), dictation is ephemeral and skipped
        // entirely below.
        let willSummarize = settings.autoSummarize
            && summarizer.availability == .available
            && !segments.isEmpty
            && currentMode == .meeting

        guard let dir = sessionDirectory else {
            // No session dir — shouldn't happen post-capture, but
            // bail cleanly. transcript.md never landed, no summary
            // can run, no auto-send needed.
            releaseSessionsFolderTicket()
            status = .finished
            return
        }
        let sessionID = dir.lastPathComponent

        // Mark the session as "summary in flight" BEFORE flipping
        // status — SessionDetailView observers may snap into the
        // skeleton state the moment .finished arrives and look at
        // the SessionStore set for the loading flag.
        if willSummarize {
            SessionStore.shared.beginGenerating(sessionID)
            summaryGenerationState = .generating
        } else {
            summaryGenerationState = .idle
        }

        // Refresh the History list synchronously so the row is in
        // place before the auto-open onChange handler (driven by
        // .finished) fires. Without this, MainView's deep-link
        // would land on Library with `pendingLibrarySelection`
        // pointing at an ID that hasn't been parsed yet.
        await SessionStore.shared.refresh()
        status = .finished

        if willSummarize {
            let transcriptText = fullTranscriptText
            let titleSnapshot = title
            let localeHint = localeHintForSummary
            // Transfer ticket ownership to the detached task BEFORE
            // spawning it. If the user hits Stop & save on M1 and
            // then immediately starts M2 (calendar auto-rotation,
            // hotkey, whatever), `start()` will assign a NEW ticket
            // to `self.sessionsFolderTicket` for M2 — and pre-1.0.3
            // the M1 task would later call `releaseSessionsFolderTicket()`,
            // releasing M2's ticket and silently breaking M2's file
            // writes. Snapshot here, release via `defer` on the
            // captured value only.
            let ticketSnapshot = sessionsFolderTicket
            sessionsFolderTicket = nil
            summaryTask = Task { [weak self] in
                defer { ticketSnapshot?.release() }
                await self?.finalizePostStop(
                    sessionID: sessionID,
                    directory: dir,
                    transcript: transcriptText,
                    title: titleSnapshot,
                    localeHint: localeHint
                )
            }
        } else {
            // No summary needed; release ticket + run autoSend (it
            // may still want to ship the transcript-only payload to
            // Notion / MCP). Sync here is fine — short, no LLM.
            releaseSessionsFolderTicket()
            await runAutoSendDestinations()
        }
    }

    /// Detached post-Stop pipeline: summarize → write summary.json →
    /// fan out to auto-send destinations → tell SessionStore the
    /// session is up-to-date. Each step checks `Task.isCancelled`
    /// and that `sessionDirectory` still matches the captured
    /// session ID — either guard fires if `start()` already kicked
    /// off a new recording on top of this one, in which case we
    /// bail without touching the new session's state.
    ///
    /// **Ticket ownership.** This function does NOT touch
    /// `sessionsFolderTicket`. The caller transferred ownership of
    /// the security-scoped ticket to the spawning Task via a local
    /// snapshot + `defer { snapshot?.release() }` — see the
    /// `Task { [ticketSnapshot] in ... }` block above. Doing it
    /// here would race against `start()` putting M2's ticket in the
    /// same slot (the pre-1.0.3 bug).
    private func finalizePostStop(
        sessionID: String,
        directory: URL,
        transcript: String,
        title: String,
        localeHint: String?
    ) async {
        // OSSignpost ranges around the three slow phases. Lets
        // `xctrace export --xpc Daisy --tracing-key=signposts` show
        // a user "your 90-second summary spent 78s in the LLM call
        // and 12s in autoSend". Ships nothing off-device — Apple
        // System Log only. The signpost subsystem matches the
        // logger subsystem so they coalesce in Console.app.
        let signposter = OSSignposter(subsystem: "app.essazanov.Daisy", category: "PostStop")

        let summarizeState = signposter.beginInterval("summarize", id: signposter.makeSignpostID())
        let summary = await summarizer.summarize(
            transcript: transcript,
            title: title,
            localeHint: localeHint
        )
        signposter.endInterval("summarize", summarizeState)

        if Task.isCancelled {
            summaryGenerationState = .failed("cancelled")
            await SessionStore.shared.finishGenerating(sessionID)
            summaryTask = nil
            return
        }

        if let summary {
            let writeState = signposter.beginInterval("write_summary", id: signposter.makeSignpostID())
            let url = directory.appendingPathComponent("summary.json")
            do {
                let data = try JSONEncoder().encode(summary)
                try data.write(to: url)
            } catch {
                log.error("Failed to write summary.json: \(error.localizedDescription, privacy: .public)")
                ToastCenter.shared.show(
                    "Couldn't save summary file. Check Console for details.",
                    style: .error
                )
            }
            signposter.endInterval("write_summary", writeState)
        }

        // If a fresh recording has begun in the meantime (reset()
        // ran), instance state has rotated and autoSend would push
        // the WRONG session to Notion/MCP. Skip — user can resend
        // manually from History.
        if Task.isCancelled || sessionDirectory?.lastPathComponent != sessionID {
            summaryGenerationState = .failed("cancelled")
            await SessionStore.shared.finishGenerating(sessionID)
            summaryTask = nil
            return
        }

        let autoSendState = signposter.beginInterval("auto_send", id: signposter.makeSignpostID())
        await runAutoSendDestinations()
        signposter.endInterval("auto_send", autoSendState)

        summaryGenerationState = (summary != nil) ? .ready : .failed("no summary")
        summaryTask = nil
        await SessionStore.shared.finishGenerating(sessionID)
    }

    /// Fan the just-finished session out to any destination the
    /// user marked as auto-on-save: Notion (per
    /// `settings.autoSendNotion`) and every enabled MCP integration
    // MARK: - Voice fingerprint matching

    /// Walk the system-side diarization centroids, match each one
    /// against the persistent `SpeakerProfileStore`, and write a
    /// `speakers.json` sidecar with the raw centroids so a later
    /// manual rename in SessionDetailView can create/update profiles.
    /// Auto-matched names land in `initialSpeakerMap` for the
    /// MarkdownExporter to embed in the transcript frontmatter.
    private func applySpeakerProfileMatches() {
        let centroids = systemTranscriber.speakerCentroids
        guard !centroids.isEmpty else { return }

        let store = SpeakerProfileStore.shared
        var matched: [String: String] = [:]
        for (speakerID, embedding) in centroids {
            if let profile = store.findMatch(for: embedding) {
                matched[speakerID] = profile.name
                store.recordMatch(profileID: profile.id)
                // profile.name is PII — speakers the user has named
                // by hand ("John", "Maria"). Speaker ID (Remote A, B,
                // …) stays public, the name does not.
                log.info("Auto-matched \(speakerID, privacy: .public) → \(profile.name, privacy: .private)")
            }
        }
        initialSpeakerMap = matched

        // Persist sidecar regardless of whether matches happened —
        // even an unmatched session needs centroids on disk so the
        // user can name them later and we'll know which embedding
        // to associate with the new profile.
        guard let dir = sessionDirectory else { return }
        let url = dir.appendingPathComponent("speakers.json")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(SpeakerCentroidsFile(centroids: centroids))
            try data.write(to: url, options: [.atomic])
        } catch {
            log.error("Failed to write speakers.json: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// whose `autoOnSave` flag is on.
    ///
    /// Errors are surfaced as toasts AND persisted into
    /// `.send_failures.json` inside the session directory — pre-1.0.3
    /// behaviour was toast-only, so a Notion 401 (or a Linear MCP
    /// timeout, or a webhook 503) vanished after a few seconds with
    /// no forensic trail. Users would email "I thought it went to
    /// Notion" with nothing to debug. The sidecar gives support a
    /// concrete artifact and lays groundwork for a future "Resend
    /// failed" affordance in History.
    private func runAutoSendDestinations() async {
        let sessionFolderSlug = folder.slug

        // Notion uses the in-memory `MeetingExportData` shape we
        // already hand to the manual Send-to flow — no need to
        // round-trip through StoredSession.
        if settings.autoSendNotion, settings.hasNotionCredentials, !segments.isEmpty,
           Self.folderAllowed(sessionFolderSlug, allowed: settings.autoSendNotionFolders) {
            let export = exportData()
            do {
                let url = try await NotionExporter.shared.createMeetingPage(export)
                ToastCenter.shared.show("Sent to Notion · \(title)", style: .success)
                // Notion URL stays .private — same reasoning as in
                // NotionExporter: page ID is a capability identifier
                // for the user's workspace.
                log.info("Auto-sent to Notion: \(url.absoluteString, privacy: .private)")
            } catch {
                log.error("Auto-send to Notion failed: \(error.localizedDescription, privacy: .private)")
                ToastCenter.shared.show("Auto-send to Notion failed — retry from History", style: .warning)
                recordAutoSendFailure(
                    integration: "Notion",
                    kind: "notion",
                    destination: "user's Notion workspace",
                    error: error.localizedDescription
                )
            }
        }

        // MCP integrations need a `StoredSession`; build one from
        // the in-memory state (the matching `SessionStore.refresh`
        // pass that would normally produce it hasn't happened yet).
        let autoIntegrations = MCPIntegrationStore.shared.autoOnSaveIntegrations
            .filter { Self.folderAllowed(sessionFolderSlug, allowed: $0.allowedFolders) }
        guard !autoIntegrations.isEmpty,
              let directory = sessionDirectory else { return }
        let stored = Self.makeStoredSession(
            id: directory.lastPathComponent,
            directory: directory,
            title: title,
            startedAt: startedAt ?? Date(),
            elapsedSec: Int(elapsed.rounded()),
            locale: localeIdentifier,
            segments: segments,
            summary: summarizer.lastSummary,
            folderSlug: sessionFolderSlug,
            client: client
        )
        for integration in autoIntegrations {
            let ok = await MCPDispatcher.send(integration, for: stored)
            if !ok {
                // MCPDispatcher already surfaced a toast and logged
                // the detailed error via os_log. The sidecar gets a
                // generic failure record — users grep Console.app
                // by subsystem `app.essazanov.Daisy` category
                // `MCPDispatcher` for the specifics. A future
                // refactor of MCPDispatcher.send() to return
                // (Bool, String?) would let us record the error
                // text here too; not blocking on it for 1.0.3.
                recordAutoSendFailure(
                    integration: integration.name,
                    kind: integration.kind == .mcp ? "mcp" : "webhook",
                    destination: integration.baseURL,
                    error: nil
                )
            }
        }
    }

    /// One entry in the per-session auto-send failure log.
    /// Stored as JSON inside `<sessionDir>/.send_failures.json`.
    ///
    /// Schema is part of the on-disk contract; future versions can
    /// add OPTIONAL fields but must not rename or remove existing
    /// ones — old Daisy versions reading sidecars written by newer
    /// versions should still decode successfully.
    nonisolated struct SendFailureRecord: Codable, Sendable {
        let integration: String     // human-readable name ("Notion", "Linear", "Slack webhook")
        let kind: String            // "notion" | "mcp" | "webhook"
        let destination: String     // URL or workspace identifier
        let error: String?          // localised error description, nil if not captured
        let attemptedAt: Date
    }

    /// Append a `SendFailureRecord` to `.send_failures.json` inside
    /// the current session directory. Atomic write — reads existing
    /// JSON array (or starts fresh on missing/malformed), appends,
    /// writes back. Hidden filename so it doesn't appear in History
    /// row contents.
    ///
    /// Failure modes silently log but don't propagate — losing the
    /// sidecar on a write error is fine; the toast + os_log already
    /// surfaced the original issue.
    private func recordAutoSendFailure(
        integration: String,
        kind: String,
        destination: String,
        error: String?
    ) {
        guard let directory = sessionDirectory else { return }
        let sidecarURL = directory.appendingPathComponent(".send_failures.json")
        var records: [SendFailureRecord] = []
        if let existing = try? Data(contentsOf: sidecarURL),
           let decoded = try? JSONDecoder.daisySendFailureDecoder.decode([SendFailureRecord].self, from: existing) {
            records = decoded
        }
        records.append(SendFailureRecord(
            integration: integration,
            kind: kind,
            destination: destination,
            error: error,
            attemptedAt: Date()
        ))
        do {
            let data = try JSONEncoder.daisySendFailureEncoder.encode(records)
            try data.write(to: sidecarURL, options: [.atomic])
            log.info("Wrote .send_failures.json (\(records.count, privacy: .public) record(s))")
        } catch {
            log.error("Failed to write .send_failures.json: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Folder allow-list check used by both Notion and MCP auto-
    /// send paths. Empty allow-list means "every folder" — the
    /// simple default. Non-empty restricts to exactly those slugs.
    nonisolated static func folderAllowed(_ slug: String, allowed: Set<String>) -> Bool {
        allowed.isEmpty || allowed.contains(slug)
    }

    /// Centralised cleanup for the early-return paths in `start()`.
    /// Before 1.0.3 each early `return` only set `status = .failed(...)`
    /// — but by that point we'd already acquired the sandbox ticket
    /// (`makeSessionDirectory()` ran before the Whisper check) and
    /// started one or both transcribers. The leftover scoped resource
    /// held until the next `start()` or `reset()`, and any in-flight
    /// transcribers kept consuming buffers from a recorder that never
    /// actually started. `failFast` collapses all of that into one
    /// idempotent cleanup: release the ticket, stop both transcribers,
    /// stop the recorder + system-audio capture, cancel auto-stop
    /// timers, then flip the status. Safe to call multiple times.
    private func failFast(_ message: String) {
        log.error("Session start failed: \(message, privacy: .public)")
        releaseSessionsFolderTicket()
        micTranscriber.reset()
        systemTranscriber.reset()
        // recorder/systemAudio may not have started yet on early
        // paths (Whisper-failed branches) — reset is idempotent.
        recorder.reset()
        Task { await systemAudio.stop() }
        screenshots.stop()
        silenceMonitor.stop()
        cancelAutoStop()
        sessionDirectory = nil
        micArchiveURL = nil
        systemArchiveURL = nil
        startedAt = nil
        status = .failed(message)
    }

    /// Public companion to `assembleStoredSession` — call sites
    /// (the Send-to popover, the toolbar) need a StoredSession to
    /// hand to MCPDispatcher when the session is still active and
    /// hasn't yet been picked up by SessionStore. Returns a
    /// best-effort snapshot built from current in-memory state.
    func snapshotStoredSession() -> StoredSession {
        let directory = sessionDirectory ?? URL(fileURLWithPath: "/tmp")
        return Self.makeStoredSession(
            id: directory.lastPathComponent,
            directory: directory,
            title: title,
            startedAt: startedAt ?? Date(),
            elapsedSec: Int(elapsed.rounded()),
            locale: localeIdentifier,
            segments: segments,
            summary: summarizer.lastSummary,
            folderSlug: folder.slug,
            client: client
        )
    }

    /// Stitch the just-finished session's in-memory state into a
    /// `StoredSession` value. Synchronous so it can serve both the
    /// post-`stop` auto-send path (called in async context) and the
    /// snapshot path used by manual Send-to.
    nonisolated static func makeStoredSession(
        id: String,
        directory: URL,
        title: String,
        startedAt: Date,
        elapsedSec: Int,
        locale: String,
        segments: [TranscriptSegment],
        summary: MeetingSummary?,
        folderSlug: String,
        client: String = ""
    ) -> StoredSession {
        let transcriptText = segments
            .map { "\($0.text)" }
            .joined(separator: " ")
        let preview = String(transcriptText.prefix(220))
        let transcriptURL = directory.appendingPathComponent("transcript.md")
        let micURL = directory.appendingPathComponent("microphone.caf")
        let systemURL = directory.appendingPathComponent("system_audio.caf")
        return StoredSession(
            id: id,
            directoryURL: directory,
            title: title,
            startedAt: startedAt,
            durationSec: elapsedSec,
            locale: locale,
            transcriptPreview: preview,
            transcriptText: transcriptText,
            hasMicAudio: FileManager.default.fileExists(atPath: micURL.path),
            hasSystemAudio: FileManager.default.fileExists(atPath: systemURL.path),
            screenshotURLs: [],
            summary: summary,
            transcriptURL: FileManager.default.fileExists(atPath: transcriptURL.path) ? transcriptURL : nil,
            folderSlug: folderSlug,
            client: client,
            meetingAttendees: [],
            speakerMap: [:]
        )
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
        // Best-effort cancel of any post-Stop finalize task. start()
        // already cancels first (so this is usually a no-op), but
        // direct reset() callers — e.g. an early-return after a Stop
        // that captured no audio — need it too.
        summaryTask?.cancel()
        summaryTask = nil
        summaryGenerationState = .idle
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
        client = ""
        currentMode = .meeting
        status = .idle
    }

    // MARK: - Computed

    var fullTranscriptText: String {
        let nonEmpty = segments
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        switch currentMode {
        case .meeting:
            // Multi-speaker context — labels are signal ("[Egor]"
            // vs "[Alex]" vs "[Remote A]" tell the LLM who said
            // what for the summary pass). User's own voice uses
            // the configured display name when set; otherwise
            // falls back to the generic "Me".
            let myName = settings.userDisplayName
            return nonEmpty
                .map { "[\($0.speakerLabel(displayName: myName))] \($0.text)" }
                .joined(separator: "\n\n")
        case .voiceNote, .dictation:
            // Single-speaker, no diarization, no LLM downstream.
            // The speaker tag is noise — for dictation it'd end
            // up pasted into the user's text field as "[Me] hi
            // there", which is exactly what they don't want.
            //
            // Joined with " " (not "\n") because each entry in
            // `segments` is one Whisper VAD chunk — a pause-bounded
            // run of speech, NOT a paragraph. Pre-1.0.5 we joined
            // with single newlines, which made dictated text look
            // shredded: every breath turned into a line break.
            // Now consecutive chunks flow into one continuous
            // string, with each chunk's own punctuation handling
            // sentence boundaries. The model usually emits a
            // trailing space inside `.text`; we trim duplicates
            // afterwards so we never produce double spaces.
            let joined = nonEmpty
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .joined(separator: " ")
            // Collapse any accidental double-spaces from per-chunk
            // trim artefacts. Single regex sweep, cheap.
            return joined.replacingOccurrences(
                of: "  +",
                with: " ",
                options: .regularExpression
            )
        }
    }

    var hasContent: Bool {
        segments.contains(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    /// Proxy for `systemAudio.hasReceivedAudio` so MarkdownExporter
    /// (and other read-only consumers outside this type) can persist
    /// the system-audio capture outcome without us widening
    /// `systemAudio`'s visibility. True == at least one PCM frame
    /// landed during the session; false == capture was armed but
    /// stayed silent (usually BT output) OR was never armed.
    var hasCapturedSystemAudio: Bool {
        systemAudio.hasReceivedAudio
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

    /// Two-letter ISO code that pins the *summary* language. Reads
    /// from the canonical resolver so the post-Stop auto-summary and
    /// the manual Re-summarize button in SessionDetailView can never
    /// drift apart and produce different languages for the same
    /// transcript.
    private var localeHintForSummary: String? {
        Self.resolveSummaryLocaleHint(
            transcript: fullTranscriptText,
            transcriptLocale: localeIdentifier,
            summaryLanguageOverride: settings.summaryLanguage
        )
    }

    /// **Single source of truth** for "what language should this
    /// summary be in?". Used by both the post-Stop detached pipeline
    /// (via `localeHintForSummary`) and SessionDetailView's manual
    /// Re-summarize button. Inconsistency between those two paths
    /// is what produced the QA-reported "first summary was Russian,
    /// pressing Re-summarize gave English" bug — the manual path
    /// used to bypass language detection entirely and naively trust
    /// the frontmatter locale tag.
    ///
    /// **Contract — explicit picker wins.** A user who deliberately
    /// picks "Polish" in Settings → Summary language wants Polish
    /// summaries regardless of what NLLanguageRecognizer thinks the
    /// transcript was in. Previously detection beat the picker so a
    /// Polish-pick + Russian-transcript always produced Russian
    /// summary, which looked like a localization bug from the user's
    /// seat. The detection path is now the FALLBACK for the "Auto"
    /// case — that's the explicit "let Daisy figure it out" mode.
    ///
    /// Precedence:
    ///   1. `summaryLanguageOverride` (when not "auto" and not empty)
    ///      — explicit user pick wins, period.
    ///   2. **`LanguageDetector.detect(transcript)`** — only consulted
    ///      when the picker is "Auto". Returns nil for too-short /
    ///      low-confidence input so the next fallback runs.
    ///   3. `transcriptLocale` prefix (when not "auto" / empty) —
    ///      user-pinned recording locale from frontmatter.
    ///   4. `nil` — truly unknown, model decides on its own.
    ///
    /// Note: the Re-summarize action passes through the same path,
    /// so an "Auto" session re-summarized produces the same answer
    /// twice (the original concern that drove the previous inversion).
    /// An "Auto + transcript too short for detection" session
    /// previously produced "match transcript settings" → now produces
    /// the same `nil` consistently. That's the right deterministic
    /// behaviour either way.
    nonisolated static func resolveSummaryLocaleHint(
        transcript: String,
        transcriptLocale: String,
        summaryLanguageOverride: String
    ) -> String? {
        // 1. Explicit picker wins. "Auto" intentionally falls through.
        if !summaryLanguageOverride.isEmpty,
           summaryLanguageOverride != SummaryLanguage.auto.id {
            return summaryLanguageOverride
        }
        // 2. Auto mode → content-driven detection.
        if let detected = LanguageDetector.detect(transcript) {
            return detected
        }
        // 3. Transcript locale frontmatter as last resort hint.
        let prefix = transcriptLocale
            .split(separator: "-")
            .first
            .map(String.init)?
            .lowercased()
        if let prefix, prefix != "auto", !prefix.isEmpty {
            return prefix
        }
        // 4. Model decides on its own.
        return nil
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
