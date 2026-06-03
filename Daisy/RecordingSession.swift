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

    /// Post-stop audit verdict for an individual archive file (.caf
    /// on disk). Distinct from the live `SystemAudioStatus` /
    /// recording-state machine — this is what the user sees in the
    /// transcript frontmatter and in any "save outcome" toast.
    ///
    /// Pre-1.0.7.1 the frontmatter only distinguished off / captured /
    /// empty, all derived from in-memory `hasReceivedAudio`. The
    /// Billions 2026-05-25 test exposed the silent case missing from
    /// that taxonomy: SCKit was delivering buffers (transcriber got
    /// 44 min), AVAudioFile.write was throwing mid-session (every
    /// frame after some point), and the frontmatter still proudly
    /// stamped `captured` because at least ONE buffer had arrived
    /// before things went sideways. `.truncated` is the new fourth
    /// state — surfaced as a post-stop warning toast AND a grep-able
    /// frontmatter line.
    enum ArchiveStatus: Equatable {
        /// User had the toggle disabled (system) or stream isn't
        /// applicable to mode (mic in dictation-only mode). No file
        /// was expected.
        case off
        /// File exists, frames-written matches expected within a
        /// reasonable tolerance, on-disk byte count is non-trivial.
        case captured(bytes: Int64)
        /// Stream was armed but zero frames ever arrived (BT output,
        /// SCKit Tahoe regression, denied permission). User saw a
        /// mid-recording warning toast (silenceMonitor) but also gets
        /// this in the frontmatter for post-hoc grep.
        case empty
        /// **The silent-write-death case.** Frames arrived in callbacks
        /// (hasReceivedAudio=true) but disk-write count is far below
        /// what was received, or the file size is < header threshold
        /// despite reported frames, or a non-trivial number of write
        /// errors fired. User gets a loud toast at stop time so they
        /// know their audio is partial.
        case truncated(bytes: Int64, framesWritten: UInt64, writeErrors: Int)
    }

    private(set) var status: Status = .idle

    /// Post-Stop summary lifecycle. Set to `.generating` the moment
    /// `stop()` spins up the detached finalize task; flips to
    /// `.ready` when summary.json is written + autoSend ran; flips
    /// to `.failed` if summarizer threw or task was cancelled by a
    /// fresh recording. Drives the SessionDetailView skeleton + the
    /// widget's amber-pulse "summary cooking" indicator.
    private(set) var summaryGenerationState: SummaryGenerationState = .idle

    /// Detached task spun up by `stop()` that handles the full post-
    /// stop pipeline (final Whisper pass → speaker match → re-render
    /// transcript.md → summary → autoSend → audio purge). Held so a
    /// fresh `start()` / `reset()` can cancel it. Kept
    /// @ObservationIgnored because the Task reference itself isn't
    /// UI-relevant — only `summaryGenerationState` is.
    @ObservationIgnored
    private var summaryTask: Task<Void, Never>?

    /// Monotonic generation counter for `summaryTask`. Bumped on
    /// every spawn. The finalize task captures its own generation at
    /// spawn time, and only clears `summaryTask` at exit when its
    /// captured generation still matches `summaryTaskGeneration` —
    /// i.e., when no fresh `stop()` has rotated the slot to a newer
    /// task in the meantime. Without this, the race is:
    ///   1. M1 stop → spawn T1 (gen=1)
    ///   2. User starts M2 → `start()` cancels T1, nils slot
    ///   3. M2 stop → spawn T2 (gen=2)
    ///   4. T1 wakes from Whisper, sees Task.isCancelled, runs
    ///      `bailRotated` which would `summaryTask = nil`,
    ///      clobbering T2's reference — T2 is now uncancellable.
    /// Generation check at exit (`if myGen == summaryTaskGeneration`)
    /// makes T1's cleanup a no-op once T2 has rotated past it.
    @ObservationIgnored
    private var summaryTaskGeneration: UInt = 0

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

    /// Free-form tag for this session. Persisted to frontmatter as
    /// `daisy_tag:` and used for grouping in History (sidebar
    /// selector + chip in the row). Empty string == "untagged"
    /// (the default). `TagSuggestion.suggest(from:)` pre-fills
    /// this when the session is bound to a calendar event with
    /// attendees from an external organization. Renamed from
    /// `client` in 1.0.5.2 — kept the same backing field, just a
    /// more generic user-facing name.
    var tag: String = ""

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
    /// Live audio spectrum (6 voice-tuned bands, 0…1) used by the floating
    /// Daisy widget to animate its petals — the lower 4 drive the 8 petals,
    /// mirrored for symmetry. Forwarded from the mic recorder.
    var spectrumBands: [Float] { recorder.spectrumBands }
    /// Every archived audio file the mic recorder produced for this
    /// session. Always at least `[microphone.caf]` while recording;
    /// becomes `[microphone.caf, microphone.part2.caf, …]` when a
    /// mid-session route change forced a format-rollover into a
    /// new part. Exposed for `MarkdownExporter` frontmatter +
    /// future History-pane "this session has N audio parts"
    /// affordance.
    var archivedAudioParts: [URL] { recorder.archivedParts }

    /// Merged transcript across mic + system, sorted by absolute start
    /// time. Cached behind a `(mic.segmentsVersion, system.segmentsVersion)`
    /// composite key — see build 41 comment on `Transcriber.segmentsVersion`
    /// for the why. Tl;dr: pre-build-41 this re-sorted both arrays on
    /// every Observable read, and on a 53-min session (1000+ segments
    /// per transcriber) that drowned the MainActor; pause/resume clicks
    /// queued behind ~8 seconds of accumulated sort work, the widget
    /// flower animation stalled at 0 fps.
    ///
    /// Cache hits when both transcribers' versions match the snapshot
    /// captured at last sort. Reading their `segmentsVersion` registers
    /// them in Observable dependency tracking, so when either transcriber
    /// mutates, the current view scope invalidates and re-reads here.
    var segments: [TranscriptSegment] {
        let micV = micTranscriber.segmentsVersion
        let sysV = systemTranscriber.segmentsVersion
        if _segmentsCacheMicVersion == micV && _segmentsCacheSysVersion == sysV {
            return _segmentsCache
        }
        let merged = (micTranscriber.segments + systemTranscriber.segments)
            .sorted(by: { $0.startedAt < $1.startedAt })
        _segmentsCache = merged
        _segmentsCacheMicVersion = micV
        _segmentsCacheSysVersion = sysV
        return _segmentsCache
    }
    @ObservationIgnored
    private var _segmentsCache: [TranscriptSegment] = []
    @ObservationIgnored
    private var _segmentsCacheMicVersion: Int = -1
    @ObservationIgnored
    private var _segmentsCacheSysVersion: Int = -1

    /// `segments` minus empty / whitespace-only lines, cached behind the
    /// same `(mic, system) segmentsVersion` composite key as `segments`.
    /// The live transcript popover reads this so SwiftUI does not run an
    /// O(N) `.filter` (plus a `String` allocation per segment) on every
    /// body re-evaluation — pre-this, `ContentView.filteredSegments` was
    /// recomputed 3-4× per render and again every `liveIntervalSec` pass.
    /// Predicate is byte-for-byte the old `filteredSegments` one, so
    /// behaviour is unchanged; the filter just runs once per mutation.
    /// Reading the transcribers' `segmentsVersion` here registers the
    /// Observable dependency, so this cache invalidates exactly when
    /// `segments` does.
    var displaySegments: [TranscriptSegment] {
        let micV = micTranscriber.segmentsVersion
        let sysV = systemTranscriber.segmentsVersion
        if _displayCacheMicVersion == micV && _displayCacheSysVersion == sysV {
            return _displayCache
        }
        let filtered = segments.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        _displayCache = filtered
        _displayCacheMicVersion = micV
        _displayCacheSysVersion = sysV
        return _displayCache
    }
    @ObservationIgnored
    private var _displayCache: [TranscriptSegment] = []
    @ObservationIgnored
    private var _displayCacheMicVersion: Int = -1
    @ObservationIgnored
    private var _displayCacheSysVersion: Int = -1

    /// Derived from `SystemAudioCapture.state` + the once-per-session
    /// denial flag set when preflight rejected us at start. UI binds
    /// to this for a "Other side: capturing / off" pill so users see
    /// mid-recording whether the remote party is actually being
    /// captured.
    var systemAudioStatus: SystemAudioStatus {
        // System audio is only meaningful in meeting mode. Voice
        // notes and dictation are personal-mic-only flows by design
        // — the user is the only voice that matters. start() skips
        // the SCStream wiring entirely for those modes, so
        // `systemAudio.state` stays at `.idle`, which would otherwise
        // fall through to the `.failed("Capture stopped unexpectedly")`
        // case below and surface a bogus warning for a recording
        // that is working exactly as intended. Map non-meeting modes
        // to `.disabled` so the status pill hides itself.
        guard currentMode == .meeting else { return .disabled }
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
    /// Microphone recorder — direct CoreAudio AUHAL capture. Stored as
    /// the concrete type (not an existential) so SwiftUI Observation
    /// tracks its `levelDB` / `spectrumBands` through the concrete
    /// `@Observable` class. (Previously selectable against a legacy
    /// AVAudioEngine `AudioRecorder` behind `useCoreAudioMicCapture`;
    /// that flag and backend were removed once CoreAudio was validated.)
    private let recorder: CoreAudioMicRecorder
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

    /// Silence-gated auto-stop state (2026-06-01). Auto-stop no longer
    /// fires at a fixed endDate+grace; it waits for a quiet stretch past
    /// the scheduled end (or a hard maximum). `autoStopWarned` latches
    /// once the 30s warning + pending stop are armed; `autoStopLastAudibleAt`
    /// is the last time mic OR system audio cleared `autoStopAudibleFloorDB`.
    private var autoStopWarned: Bool = false
    private var autoStopLastAudibleAt: Date?

    /// Once past endDate+grace, stop only after this much continuous quiet
    /// on BOTH mic and system. A live conversation never has this long a
    /// gap; a finished meeting does.
    private static let autoStopSilenceToStopSec: TimeInterval = 120
    /// Absolute backstop: stop unconditionally this long past the scheduled
    /// end even if audio is still flowing (background music, forgotten
    /// call), so a left-running session can't record forever.
    private static let autoStopMaxOverrunSec: TimeInterval = 30 * 60
    /// Peak-dBFS floor above which mic/system counts as "audible" for
    /// auto-stop gating. Higher than the −80 dB liveness floor: room tone
    /// shouldn't keep a finished meeting alive, but speech easily clears it.
    private static let autoStopAudibleFloorDB: Float = -55
    /// How often the silence-gated evaluator re-checks.
    private static let autoStopEvalIntervalSec: TimeInterval = 10

    // ─── Low-disk guard (transcript-only fallback) ───────────────────
    /// True when this session is transcript-only because of low disk (set
    /// at start or after a mid-recording switch). Stops the disk monitor
    /// from firing twice.
    @ObservationIgnored
    private var diskTranscriptOnly = false
    @ObservationIgnored
    private var diskMonitorTimer: Timer?
    /// Below this much free space at start → record transcript-only.
    private static let lowDiskStartThresholdBytes: Int64 = 3 * 1_073_741_824      // 3 GB
    /// Below this much free space mid-recording → auto-switch to transcript-only.
    private static let lowDiskCriticalThresholdBytes: Int64 = 1_536 * 1_048_576   // 1.5 GB
    /// Disk-space poll cadence while recording.
    private static let diskMonitorIntervalSec: TimeInterval = 45

    /// Live tier the active session STARTED with — the restore target once
    /// thermal/low-power pressure clears. Only Full sessions auto-downgrade.
    @ObservationIgnored
    private var startedLiveTier: LiveTranscriptionTier = .full
    /// True while a thermal/low-power auto-downgrade (Full→Lite) is in
    /// effect. Runtime only — never written to `settings.liveTranscriptionTier`.
    @ObservationIgnored
    private var thermalDowngradeActive = false
    @ObservationIgnored
    private var thermalObserver: NSObjectProtocol?
    @ObservationIgnored
    private var powerObserver: NSObjectProtocol?

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
        // Direct CoreAudio AUHAL mic capture — the sole capture backend.
        // (The legacy AVAudioEngine `AudioRecorder` and the
        // `useCoreAudioMicCapture` switch were removed once CoreAudio was
        // validated as the default.)
        self.recorder = CoreAudioMicRecorder()
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
            source: .systemAudio,
            // 2026-05-25 — diarization on the remote stream is now
            // user-gated via `settings.diarizeRemoteSpeakers`. Default
            // true preserves the historical per-voice clustering;
            // false collapses every system-audio segment to a single
            // "Remote" label (Granola-style two-side mode). Useful
            // for users hitting pyannote over-segmentation on
            // rapid-fire dialogue with similar voices.
            diarize: settings.diarizeRemoteSpeakers
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

        // 1.0.5.1 hotfix: REMOVED recorder.prewarm() — calling
        // AVAudioEngine.prepare() at app-init time crashes the
        // process on macOS 26.2 because the engine's input graph
        // isn't initializable until microphone permission is
        // granted AND the user actually intends to record. The
        // ObjC NSException AVAudioEngineGraph::Initialize threw
        // propagates straight through Swift and aborts the process
        // before SwiftUI even mounts. Cold-start lag is a worse
        // problem than no lag — but a crash on launch is worse
        // than both. Re-introduce gated on
        // `SystemPermissions.shared.microphone == .granted` in a
        // future release, or move prewarm to the first user-
        // initiated record() call where the engine state is sane.

        // Probe the configured summary provider once so its status
        // (Available / Unavailable) is known before the user opens
        // Settings → Summary for the first time. Without this, the
        // first visit to that tab shows "Checking…" for ~1s before
        // resolving.
        Task { await Summarizer.shared.refreshAvailability() }

        // Audio retention sweep — deletes raw .caf archives older
        // than the user-configured cutoff. No-op when
        // audioRetentionDays == 0 (default, preserves backwards-
        // compat). Runs detached on a background queue.
        AudioRetentionSweep.runIfNeeded(retentionDays: settings.audioRetentionDays)

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
            await pause()
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
        // 2026-05-25: previously we set `title = meeting.title` here
        // because reset() didn't clear title. That created the bug
        // where a meeting's name leaked into a later voice-note
        // session days afterward (stale title sat in memory the whole
        // time). Now reset() clears title, and start()'s title-
        // generation block picks up `boundMeeting.title` directly when
        // the mode is meeting + a binding exists. No need to set
        // title here at all.

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
            if tag.isEmpty, let suggested = TagSuggestion.suggest(from: m.attendeeEmails) {
                tag = suggested
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
            // Mode-aware default title. Pre-1.0.6.3 every session
            // (meeting, voice note, dictation) got the "Meeting …"
            // prefix regardless of `currentMode`, which made voice
            // notes look like miscategorised meetings in the
            // History sidebar. Now the title reflects what the
            // session actually is — the user's expectation when
            // they tap the voice-notes hotkey is a Library entry
            // that reads "Voice note", not "Meeting".
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm"
            let prefix: String
            switch currentMode {
            case .meeting:   prefix = "Meeting"
            case .voiceNote: prefix = "Voice note"
            case .dictation: prefix = "Dictation"
            }
            title = "\(prefix) \(f.string(from: Date()))"
        }

        status = .preparing

        // First-record explainer toast.
        //
        // If Whisper isn't yet `.ready`, the user is about to wait
        // 1-3 minutes while the 626 MB model downloads + CoreML loads.
        // The widget centre + tooltip surface the live progress, but
        // a one-shot toast at the moment of click gives the user a
        // concrete "how long" so they don't think the app is hung.
        // Skip the toast when prewarm has already finished — most
        // sessions land in `.ready` here, and a "model is loading"
        // toast on a sub-second startup would be noise.
        switch WhisperEngine.shared.state {
        case .notLoaded, .downloading, .loading:
            ToastCenter.shared.show(
                "Setting up transcription model — first run only, about 1–3 minutes",
                style: .info
            )
        case .ready, .failed:
            break
        }

        // Make sure Whisper is ready before we tap the mic — otherwise the
        // user sees "Recording…" with nothing happening. Each early-exit
        // path below goes through `failFast(_:)` so we don't leak the
        // sandbox ticket from `makeSessionDirectory()` or the half-
        // started transcribers — pre-1.0.3 these `return`s left
        // `sessionsFolderTicket` retained until the next start/reset.
        await WhisperEngine.shared.ensureLoaded()
        if case .failed(let msg) = WhisperEngine.shared.state {
            await failFast("Whisper model failed to load: \(msg)")
            return
        }
        guard WhisperEngine.shared.isReady else {
            await failFast("Whisper model isn't ready yet — try again in a moment.")
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

        // Pattern (d) per the 2026-05-28 competitor research:
        // when audioRetentionDays == audioRetentionDoNotRecord (-2),
        // skip the on-disk .caf archives entirely. AVAudioFile is
        // never opened on the mic tap, SCStream's archiveWriter is
        // never lazy-opened on the system-audio path. Whisper still
        // gets full audio via the live AsyncStream<AudioChunk>
        // continuations so transcript quality is unaffected — only
        // the disk artifact is gone. Strongest privacy posture in
        // the Storage picker; the trade-off is no crash-recovery
        // (if Daisy goes away mid-meeting, transcript is lost too)
        // and no "re-summarize with a better model" after the fact.
        let skipForRetention = settings.audioRetentionDays == AppSettings.audioRetentionDoNotRecord
        // Low-disk guard (2026-06-01, Egor's "auto + notify"): if the volume
        // is below the start threshold, record TRANSCRIPT-ONLY this session —
        // audio is the heavy part (~0.7 GB/hr) and would fill the disk. Reuses
        // the same skip-archive path as the "Don't record audio" retention
        // mode (Whisper still gets full audio via the live stream).
        let freeAtStart = Self.freeDiskBytes(at: dir)
        let lowDiskAtStart = !skipForRetention && (freeAtStart ?? .max) < Self.lowDiskStartThresholdBytes
        diskTranscriptOnly = lowDiskAtStart
        let skipAudioArchive = skipForRetention || lowDiskAtStart
        let micArchive = skipAudioArchive ? nil : dir?.appendingPathComponent("microphone.caf")
        let systemArchive = skipAudioArchive ? nil : dir?.appendingPathComponent("system_audio.caf")
        if lowDiskAtStart {
            let freeGB = Double(freeAtStart ?? 0) / 1_073_741_824
            ToastCenter.shared.show(
                String(format: "Low disk space (%.1f GB free) — recording transcript only this session, no audio. Free up space to record audio again.", freeGB),
                style: .warning,
                duration: .seconds(6)
            )
            log.warning("Low disk at start (\(freeAtStart ?? -1, privacy: .public) bytes free) — transcript-only session")
        }

        let nowStarted = Date()

        // Wire mic. Build 43: `liveTranscription` propagated from
        // AppSettings — when OFF, the transcriber accumulates audio
        // for `runFinalPass()` but doesn't fire per-window Whisper
        // commits during the meeting. Dictation mode forces live ON
        // regardless of the setting because dictation IS the live
        // transcript (paste happens on hotkey release).
        // Dictation IS the live transcript, so it always runs live at Full
        // regardless of the meeting tier; otherwise honour the user's tier.
        let tier: LiveTranscriptionTier = currentMode == .dictation ? .full : settings.liveTranscriptionTier
        let micAudio = recorder.buffers
        micTranscriber.start(consuming: micAudio, startedAt: nowStarted, tier: tier)
        do {
            try recorder.start(
                archiveURL: micArchive,
                preferredDeviceUID: settings.selectedMicDeviceUID
            )
        } catch {
            await failFast(error.localizedDescription)
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
                systemTranscriber.start(consuming: systemAudioStream, startedAt: nowStarted, tier: tier)
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
        installThermalDowngrade(startedTier: tier)
        if settings.recordingSoundsEnabled { SoundEffects.playStart(for: currentMode) }

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
        startDiskMonitor()
    }

    // MARK: - Auto-stop (calendar-bound)

    /// Schedule the auto-stop fire + 30s warning toast if the
    /// session is bound to a calendar event AND the user has the
    /// auto-stop preference on. No-op otherwise (manual sessions are
    /// never auto-stopped).
    private func scheduleAutoStopIfNeeded() {
        cancelAutoStop()
        autoStopSuppressed = false
        autoStopWarned = false
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
        let hardMax = meeting.endDate.addingTimeInterval(Self.autoStopMaxOverrunSec)
        guard hardMax > now else {
            autoStopLog.warning("scheduleAutoStop: meeting '\(meeting.title, privacy: .private)' already past end+maxOverrun (endDate=\(meeting.endDate.description, privacy: .public)) — no timer armed")
            return
        }

        // Silence-gated auto-stop (replaces the old fixed endDate+grace
        // one-shot that cut people off mid-sentence — Egor, 2026-06-01:
        // "стопнул, хотя мы ещё разговаривали"). A repeating evaluator
        // stops only once there's been `autoStopSilenceToStopSec` of quiet
        // past endDate+grace, or unconditionally at endDate+maxOverrun.
        // See evaluateAutoStop().
        autoStopLastAudibleAt = now
        autoStopTimer = Timer.scheduledTimer(
            withTimeInterval: Self.autoStopEvalIntervalSec,
            repeats: true
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.evaluateAutoStop() }
        }
        autoStopLog.info("Auto-stop armed (silence-gated) for '\(meeting.title, privacy: .private)': earliest endDate+\(self.settings.autoStopGraceSec, privacy: .public)s then \(Int(Self.autoStopSilenceToStopSec), privacy: .public)s quiet; hard max endDate+\(Int(Self.autoStopMaxOverrunSec), privacy: .public)s")
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
        // Pre-fill tag from attendee domain (most-frequent
        // external org). Same call site as the auto-binding in
        // start() so manual-start sessions also get the suggestion.
        if tag.isEmpty, let suggested = TagSuggestion.suggest(from: meeting.attendeeEmails) {
            tag = suggested
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

    // MARK: - Low-disk guard (auto transcript-only)

    private func startDiskMonitor() {
        stopDiskMonitor()
        diskMonitorTimer = Timer.scheduledTimer(
            withTimeInterval: Self.diskMonitorIntervalSec, repeats: true
        ) { [weak self] _ in
            // Rebind to a strong `let` so the Task captures by value —
            // otherwise Swift 6 flags the captured `weak self` var crossing
            // the concurrency boundary (same pattern as the auto-stop timers).
            guard let self else { return }
            Task { @MainActor in self.checkDiskSpace() }
        }
    }

    private func stopDiskMonitor() {
        diskMonitorTimer?.invalidate()
        diskMonitorTimer = nil
    }

    /// Mid-recording low-disk guard. If free space drops below the critical
    /// floor while we're still archiving audio, auto-switch to transcript-only
    /// (stop both archives, keep transcribing) + notify — Egor's 2026-06-01
    /// "auto + notify" choice. Fires once; self-terminates once recording ends.
    private func checkDiskSpace() {
        guard status == .recording else { stopDiskMonitor(); return }
        guard !diskTranscriptOnly,
              settings.audioRetentionDays != AppSettings.audioRetentionDoNotRecord,
              let free = Self.freeDiskBytes(at: sessionDirectory),
              free < Self.lowDiskCriticalThresholdBytes
        else { return }
        diskTranscriptOnly = true
        recorder.stopArchivingKeepTranscribing()
        systemAudio.stopArchivingKeepTranscribing()
        let freeGB = Double(free) / 1_073_741_824
        ToastCenter.shared.show(
            String(format: "Disk space critically low (%.1f GB) — switched to transcript only. Audio stopped to avoid filling your disk; the transcript keeps recording.", freeGB),
            style: .warning,
            duration: .seconds(7)
        )
        log.warning("Low disk mid-recording (\(free, privacy: .public) bytes free) — switched to transcript-only")
    }

    /// Repeating evaluator (every `autoStopEvalIntervalSec`) for the
    /// silence-gated auto-stop. Stops the session only once it's been
    /// quiet for `autoStopSilenceToStopSec` past endDate+grace, or
    /// unconditionally at endDate+maxOverrun. While anyone is still
    /// talking (mic OR system above the floor), the stop is deferred.
    private func evaluateAutoStop() {
        guard status == .recording || status == .paused, !autoStopSuppressed else {
            cancelAutoStop()
            return
        }
        guard let meeting = boundMeeting else { cancelAutoStop(); return }
        let now = Date()
        let earliest = meeting.endDate.addingTimeInterval(TimeInterval(settings.autoStopGraceSec))
        let hardMax = meeting.endDate.addingTimeInterval(Self.autoStopMaxOverrunSec)

        // Absolute backstop — stop no matter what's still on the line.
        if now >= hardMax {
            if !autoStopWarned { armAutoStopWarningAndStop(silence: false) }
            return
        }

        // Is anyone still talking? Either stream above the floor counts.
        let audible = recorder.levelDB > Self.autoStopAudibleFloorDB
            || systemAudio.peakLevelDB > Self.autoStopAudibleFloorDB
        if audible {
            autoStopLastAudibleAt = now
            // Conversation resumed during a pending stop — call it off.
            if autoStopWarned {
                autoStopWarningTimer?.invalidate()
                autoStopWarningTimer = nil
                autoStopWarned = false
                autoStopLog.info("Auto-stop: audio resumed past scheduled end — stop deferred")
            }
            return
        }

        // Silent right now — only consider stopping once past endDate+grace.
        guard now >= earliest else { return }
        let silentFor = now.timeIntervalSince(autoStopLastAudibleAt ?? earliest)
        if silentFor >= Self.autoStopSilenceToStopSec, !autoStopWarned {
            armAutoStopWarningAndStop(silence: true)
        }
    }

    /// Show the 30 s "Keep going" warning and arm the actual stop. Called
    /// by `evaluateAutoStop` when the quiet/overrun condition is first met.
    /// "Keep going" cancels auto-stop for the rest of the session.
    private func armAutoStopWarningAndStop(silence: Bool) {
        guard status == .recording || status == .paused, !autoStopSuppressed else { return }
        autoStopWarned = true
        let msg = silence
            ? "Meeting's been quiet for a couple of minutes — Daisy will stop & save in 30 seconds."
            : "Meeting has run well past its end — Daisy will stop & save in 30 seconds."
        ToastCenter.shared.showAction(
            msg,
            actionLabel: "Keep going",
            style: .warning,
            duration: .seconds(30)
        ) { [weak self] in
            guard let self else { return }
            self.cancelAutoStop()
            self.autoStopSuppressed = true
            ToastCenter.shared.show("Auto-stop cancelled for this session.", style: .info)
        }
        autoStopWarningTimer = Timer.scheduledTimer(
            withTimeInterval: 30,
            repeats: false
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.performAutoStop() }
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
    func pause() async {
        guard status == .recording else { return }
        recorder.pause()
        // Was: `Task { await systemAudio.pause() }` — unawaited race.
        // User who pause→resume'd quickly caught `systemAudio.state`
        // still at `.capturing` (the detached pause Task hadn't
        // completed), and `resume()`'s `guard state == .paused`
        // silently returned. Net effect: SCStream never paused, then
        // "resumed" with stale capture state → system audio went
        // silent until full Stop+Start. Build 40 fix per macOS audit:
        // make pause() async + await the SystemAudio pause so
        // `status = .paused` flips only after the pause has
        // actually committed downstream.
        await systemAudio.pause()
        micTranscriber.pause()
        systemTranscriber.pause()
        screenshots.stop()
        silenceMonitor.pause()
        status = .paused
        // Pause cue removed — it fired mid-capture (leak window) and the
        // widget colour already signals paused (gray). See SoundEffects.
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
        // Resume cue removed — same reasoning as pause (mid-capture leak
        // window + redundant with the widget colour). See SoundEffects.
        log.info("Session resumed")
    }

    func stop() async {
        // Full finalize — explicit user action. Allowed from both
        // .recording and .paused (the latter so the user can pause
        // first, change their mind, then commit). Anything else is a
        // no-op so transient states aren't interrupted.
        guard status == .recording || status == .paused else { return }
        removeThermalDowngrade()
        // No stop-click cue — it fired before capture stopped (tailing the
        // recording) and before any work finished. The "done" cue now plays
        // when `.finished` lands (SoundEffects.playFinished) — leak-safe and
        // synced to the widget's celebration pop.
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
        removeThermalDowngrade()

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
            // Two well-understood causes: Bluetooth output (macOS
            // refuses to loop BT audio through ScreenCaptureKit), and
            // a ScreenCaptureKit regression on macOS 26.0.x (early
            // Tahoe builds) where SCStream reports `.capturing` but
            // never delivers a single audio buffer even with wired or
            // built-in output. Phrase the toast neutrally so we don't
            // mislead the macOS 26 cohort into chasing a BT issue
            // they don't have.
            // 2026-05-25 — toast shortened to one line per Egor's
            // pass. Pre-fix this was a 4-sentence wall (microphone
            // track + system loopback + Tahoe regression caveat +
            // built-in-speaker workaround + diarization implication)
            // that wrapped to ~4 lines of dense text in the toast
            // surface — visually overwhelming and edge-to-edge on
            // wide displays. The same session also surfaces the
            // acousticLoopbackBanner inside SessionDetailView when
            // the user opens it, which carries the one-line warning
            // permanently (until "Got it"). The Tahoe-specific
            // "switch to built-in speakers" workaround was also
            // unreliable in tester reports — keeping it in the
            // toast set a false expectation of fix-ability.
            ToastCenter.shared.show(
                "Other side wasn't captured — only your mic was recorded this session",
                style: .warning,
                duration: .seconds(8)
            )
            log.warning("Session ended with empty system audio despite captureSystemAudio=on (no audio buffers from SCStream — BT output, or macOS 26 SCStream regression)")
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
        // Did we capture anything worth keeping? Two data-loss fixes vs.
        // the old check (which only tested the BASE microphone.caf /
        // system_audio.caf files):
        //   1. Count frames across ALL parts via `archivedFrameCount`,
        //      not just the base file. A route change — including the
        //      spurious one that fires ~24 ms after start — rolls the
        //      archive into `microphone.partN.caf` and leaves the BASE
        //      file 0 bytes. The old `fileExistsNonEmpty(micArchiveURL)`
        //      then saw "no audio" and deleted a session that actually
        //      had minutes of audio in a .partN file (real repro: 81 s
        //      recorded, live transcript fine, whole session erased on Stop).
        //   2. Never delete a session that produced transcript segments,
        //      even at zero audio frames — covers "Don't record audio"
        //      mode (the transcript IS the product) and any path where
        //      audio didn't reach disk but Whisper still committed text.
        let capturedAnyAudio =
            recorder.archivedFrameCount > 0 ||
            systemAudio.archivedFrameCount > 0
        let hasTranscript = !segments.isEmpty
        if !capturedAnyAudio && !hasTranscript {
            // Nothing usable was captured — and NEITHER branch may delete
            // a recording silently. This path has erased real recordings
            // before, and a session the user deliberately started must
            // never just vanish.
            if elapsed < 10 {
                // Genuine accidental tap (Record → immediately Stop).
                // Remove the husk, but say so — not silent.
                if let dir = sessionDirectory {
                    try? FileManager.default.removeItem(at: dir)
                    log.info("Stop: <10s and nothing captured — removed husk")
                }
                ToastCenter.shared.show(
                    "Recording too short — nothing to save",
                    style: .info,
                    duration: .seconds(3)
                )
                reset()
                return
            }
            // ≥10s but empty (e.g. the live engine silently produced
            // nothing in "Don't record audio" mode). KEEP the session and
            // warn, so it stays visible in the Library and the user can
            // act — rather than disappearing. Safe to keep: summary
            // (`willSummarize … && !segments.isEmpty`) and auto-send
            // (`!segments.isEmpty`) both already skip an empty transcript,
            // so nothing gets summarised or pushed to Notion on empty — it
            // just leaves an (empty) transcript.md the user can see.
            log.warning("Stop: \(self.elapsed, privacy: .public)s elapsed but no audio and no transcript — keeping session and warning (not deleting)")
            ToastCenter.shared.show(
                "Nothing was transcribed this session — check your mic and Settings → Transcription. The recording was kept, not discarded",
                style: .warning,
                duration: .seconds(8)
            )
            // fall through — keep the empty session instead of removing it.
        }

        // 2026-05-25 — per-stage timing for the pre-`.finished`
        // pipeline. Pre-fix every stage between Final pass and
        // status=.finished ran silently; on long sessions users
        // reported "пост-обработка очень долгая" with nothing to
        // attribute it to (see [[feedback_silent_early_returns_need_logger_category]]).
        // Mirrors the OSSignposter spans inside finalizePostStop so
        // Instruments traces and `log show --signpost` both line up
        // under PostStop category; the .info lines below are visible
        // in plain `log show ... --info --debug` as a fallback.
        let stopSignposter = OSSignposter(subsystem: "app.essazanov.Daisy", category: "PostStop")
        func ms(_ start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }

        // 2026-05-27 — TWO-STAGE STOP (1.0.7.3).
        //
        // Pre-fix this is where we ran the full Whisper final pass
        // (mic + system) inline, blocking `status = .finished` until
        // it returned. On a 20+ minute mic session this clocked
        // 237091ms in real-world logs — the user sees "Stopping…"
        // for 4 minutes and can't start the next recording. PH
        // launch is in a week and meeting-to-meeting flow is core,
        // so we changed shape.
        //
        // New shape:
        //   1. `stopCapture()` instead of `stop()` on each transcriber
        //      — drains live consumers + in-flight diarization, no
        //      final Whisper pass. Returns in well under a second.
        //   2. Render transcript.md from LIVE-accumulated segments
        //      (they're real Whisper output too, just per-window
        //      context instead of full-session context). User opens
        //      the session, sees content immediately.
        //   3. `status = .finished` fires below — user is unblocked.
        //   4. Detached task (`finalizePostStop`) runs the final
        //      Whisper pass + applySpeakerProfileMatches +
        //      re-renders/overwrites transcript.md with final
        //      quality, then continues to summary + autoSend.
        //
        // Trade-off: transcript.md is live-quality for ~tens of
        // seconds to a few minutes after Stop, then polishes
        // itself. Users who hit Stop are typically rushing to the
        // next meeting and will look at the transcript later — by
        // which time the final pass is done. Summary still uses
        // final-quality transcript (waits for re-render).
        let stopCaptureState = stopSignposter.beginInterval("stop_capture", id: stopSignposter.makeSignpostID())
        let t_stopCapture = Date()
        async let micCaptured: Void = micTranscriber.stopCapture()
        async let sysCaptured: Void = systemTranscriber.stopCapture()
        _ = await (micCaptured, sysCaptured)
        stopSignposter.endInterval("stop_capture", stopCaptureState)
        log.info("post-stop stop_capture: \(ms(t_stopCapture), privacy: .public)ms")
        // applySpeakerProfileMatches is intentionally NOT called
        // here — it depends on `speakerCentroids` which only get
        // populated by the final pass. The detached task runs it
        // after `runFinalPass()` lands.

        // 2026-05-25 — silent-write-death audit (1.0.7.1). Pre-fix the
        // only signals were `hasReceivedAudio` (in-memory flag, flips
        // true on first buffer regardless of disk write outcome) and a
        // per-write `log.error` line that no user ever sees. Result:
        // the Billions test session shipped frontmatter that claimed
        // `daisy_system_audio_status: captured` while system_audio.caf
        // was 0 bytes, mic.caf had 5% of the audio the transcript
        // referenced, and the user got zero indication anything was
        // wrong. Now: we read both ArchiveStatus values BEFORE the
        // frontmatter is rendered, log the verdict structurally for
        // `log show`, and toast if either side is truncated so the
        // user has the chance to keep the raw .caf around for repair
        // instead of letting delete-after-transcription nuke it.
        let micStatus = micAudioArchiveStatus
        let sysStatus = systemAudioArchiveStatus
        log.info("post-stop archive_audit mic: \(String(describing: micStatus), privacy: .public)")
        log.info("post-stop archive_audit system: \(String(describing: sysStatus), privacy: .public)")

        if case .truncated(let bytes, let framesWritten, let writeErrors) = micStatus {
            log.error("Mic archive TRUNCATED: \(bytes, privacy: .public) bytes on disk, \(framesWritten, privacy: .public) frames written, \(writeErrors, privacy: .public) write errors")
            ToastCenter.shared.show(
                "Mic recording is incomplete — only part of your audio made it to disk. Keep this session's folder to recover what's there.",
                style: .error,
                duration: .seconds(12)
            )
        }
        if case .truncated(let bytes, let framesWritten, let writeErrors) = sysStatus {
            log.error("System audio archive TRUNCATED: \(bytes, privacy: .public) bytes on disk, \(framesWritten, privacy: .public) frames written, \(writeErrors, privacy: .public) write errors")
            ToastCenter.shared.show(
                "Other-side audio is incomplete — capture started but the file didn't grow. Transcript may still be usable; raw audio is partial.",
                style: .error,
                duration: .seconds(12)
            )
        }

        // Dictation mode — fully ephemeral. Run the final Whisper pass
        // INLINE before reading `fullTranscriptText` (build 41 fix):
        // pre-build-41 we relied on the live windowed transcriber
        // having committed everything by the time `stopCapture()`
        // returned, but the live transcriber requires either a full
        // 14-second VAD window OR an end-of-speech silence boundary
        // to commit a segment. Short utterances ("просто для аудита",
        // ~1.2 s) released as soon as the user lifted the hotkey
        // never got either — buffer flushed silently, no transcript,
        // paste landed empty. User feedback: "цветок видит, но текст
        // не вставляется; приходится держать с тишиной".
        //
        // Final pass forces Whisper to transcribe whatever's in the
        // mic buffer regardless of VAD state. Typical <30s dictation
        // → 200-800ms decode. The Stop blocks for that window before
        // paste; price for short-utterance reliability.
        //
        // For non-dictation modes the final pass runs in the detached
        // `finalizePostStop` task after `.finished` flips — that path
        // still applies, just below.
        if currentMode == .dictation {
            await micTranscriber.runFinalPass()
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
        // `renderMarkdown` runs AcousticEchoDedup + transcript shaping
        // internally; on long sessions with hundreds of segments this
        // is the likely "long silent stage" suspect. Split into render
        // vs write so we can tell which one is slow.
        if let dir = sessionDirectory {
            let url = dir.appendingPathComponent("transcript.md")
            let renderState = stopSignposter.beginInterval("render_markdown", id: stopSignposter.makeSignpostID())
            let t_render = Date()
            let md = MarkdownExporter.renderMarkdown(session: self)
            stopSignposter.endInterval("render_markdown", renderState)
            log.info("post-stop render_markdown: \(ms(t_render), privacy: .public)ms, \(md.count, privacy: .public) bytes")

            let writeState = stopSignposter.beginInterval("write_transcript_md", id: stopSignposter.makeSignpostID())
            let t_write = Date()
            do {
                try md.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                log.error("Failed to write transcript.md: \(error.localizedDescription)")
                ToastCenter.shared.show(
                    "Couldn’t save transcript file. Check Console for details.",
                    style: .error
                )
            }
            stopSignposter.endInterval("write_transcript_md", writeState)
            log.info("post-stop write_transcript_md: \(ms(t_write), privacy: .public)ms")
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
            if settings.recordingSoundsEnabled { SoundEffects.playFinished() }
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
        let refreshState = stopSignposter.beginInterval("session_store_refresh", id: stopSignposter.makeSignpostID())
        let t_refresh = Date()
        await SessionStore.shared.refresh()
        stopSignposter.endInterval("session_store_refresh", refreshState)
        log.info("post-stop session_store_refresh: \(ms(t_refresh), privacy: .public)ms")
        status = .finished
        if settings.recordingSoundsEnabled { SoundEffects.playFinished() }

        // 2026-05-27 — ALWAYS launch the detached finalize task,
        // not just for the summary case. The final Whisper pass
        // moved out of `.stopping` and into the detached path; the
        // task now owns: runFinalPass(mic+system) → speakerMatch →
        // re-render transcript.md → (optionally) summary → autoSend
        // → audio purge. The "no summary needed" branch used to
        // skip launching the task at all; now it still launches,
        // just sets willSummarize=false so the LLM step is no-op'd.
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
        // Bump generation BEFORE spawning so the task captures the
        // post-bump value. Wrapping add (&+=) is safe — at one stop
        // per second forever this overflows in ~136 years.
        summaryTaskGeneration &+= 1
        let myGeneration = summaryTaskGeneration
        summaryTask = Task { [weak self] in
            defer { ticketSnapshot?.release() }
            await self?.finalizePostStop(
                sessionID: sessionID,
                directory: dir,
                title: titleSnapshot,
                localeHint: localeHint,
                willSummarize: willSummarize,
                generation: myGeneration
            )
        }
    }

    /// Detached post-Stop pipeline. Runs everything that used to
    /// block `.stopping` for minutes on long sessions:
    ///
    ///   1. **Final Whisper pass** on mic + system (parallel). This
    ///      is the heavy work — 237s observed on a 20-min session in
    ///      the 2026-05-27 log report. Used to sit inline in
    ///      `Transcriber.stop()`, holding `status = .stopping` until
    ///      it returned and locking the user out of starting a new
    ///      recording. Now it runs here so Stop is snappy.
    ///   2. **Speaker profile matching** — needs the final-pass
    ///      `speakerCentroids`, so it can only run after (1).
    ///   3. **Re-render transcript.md** with final-quality segments.
    ///      The inline path in `stop()` already wrote a live-quality
    ///      transcript.md; we overwrite it here with the polished
    ///      version.
    ///   4. **Summary** (if `willSummarize`) → write summary.json.
    ///   5. **Auto-send** to Notion / MCP destinations.
    ///   6. **Audio purge** if delete-after-transcription mode is on.
    ///
    /// Each stage checks `Task.isCancelled` and that `sessionDirectory`
    /// still matches the captured session ID — either guard fires if
    /// `start()` already kicked off a new recording on top of this
    /// one, in which case we bail without touching the new session's
    /// state. The render+write pair runs SYNCHRONOUSLY without an
    /// intervening await so MainActor scheduling guarantees no other
    /// task can mutate `segments` between the snapshot and the disk
    /// write.
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
        title: String,
        localeHint: String?,
        willSummarize: Bool,
        generation: UInt
    ) async {
        // OSSignpost ranges around each slow phase. Lets
        // `xctrace export --xpc Daisy --tracing-key=signposts` show
        // a user "your 4-minute finalize spent 237s in final_pass,
        // 32s in summarize, 1.2s in auto_send". Ships nothing
        // off-device — Apple System Log only. The signpost subsystem
        // matches the logger subsystem so they coalesce in
        // Console.app.
        let signposter = OSSignposter(subsystem: "app.essazanov.Daisy", category: "PostStop")
        func ms(_ start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }

        // Helper to bail cleanly when the session rotated under us.
        // Resets the generation state (only meaningful for the
        // willSummarize path, since the no-summary path never called
        // beginGenerating) and clears summaryTask — but ONLY if the
        // slot still points at us. If a fresh `stop()` has spawned a
        // newer task while we were inside Whisper, the slot now
        // holds that task's reference and nilling it would lose the
        // handle. See `summaryTaskGeneration` doc for the full race.
        @MainActor func bailRotated(stage: String) async {
            log.info("Finalize: \(stage, privacy: .public) — session rotated, bailing")
            if willSummarize {
                summaryGenerationState = .failed("cancelled")
                await SessionStore.shared.finishGenerating(sessionID)
            }
            if generation == summaryTaskGeneration {
                summaryTask = nil
            }
        }

        // ── Stage 1: Final Whisper pass ──────────────────────────────
        //
        // Both transcribers run their final pass concurrently. Each
        // re-runs Whisper over its full accumulated buffer (up to the
        // 30-min cap baked into runFinalTranscribe), producing
        // segment quality that beats the live per-window output. On
        // an M-series Mac this is CPU-bound on the Neural Engine; on
        // a 20-min mic session it clocks ~237s in production logs,
        // which is exactly why we moved it off the inline Stop path.
        //
        // `runFinalPass` is wrapped to flip `Transcriber.isRunning =
        // false` at the end — capture stopped in stop(), but
        // isRunning is intentionally held true between stopCapture()
        // and runFinalPass() because the final pass still mutates
        // committedSegments + speakerCentroids on the same instance.
        let finalPassState = signposter.beginInterval("final_pass", id: signposter.makeSignpostID())
        let t_final = Date()
        async let micFinal: Void = micTranscriber.runFinalPass()
        async let sysFinal: Void = systemTranscriber.runFinalPass()
        _ = await (micFinal, sysFinal)
        signposter.endInterval("final_pass", finalPassState)
        log.info("post-stop final_pass: \(ms(t_final), privacy: .public)ms")

        if Task.isCancelled || sessionDirectory?.lastPathComponent != sessionID {
            await bailRotated(stage: "after final_pass")
            return
        }

        // ── Stage 2: Speaker profile matching ────────────────────────
        //
        // Reads system-side speakerCentroids that the final pass just
        // populated, looks each one up in SpeakerProfileStore, and
        // writes speakers.json. Without the final pass first, this
        // would silently no-op on long sessions where the live
        // diarizer hadn't yet committed full-session centroids.
        let matchState = signposter.beginInterval("speaker_match", id: signposter.makeSignpostID())
        let t_match = Date()
        applySpeakerProfileMatches()
        signposter.endInterval("speaker_match", matchState)
        log.info("post-stop speaker_match: \(ms(t_match), privacy: .public)ms")

        // ── Stage 3: Re-render transcript.md with final-quality data ─
        //
        // The inline path in stop() wrote a transcript.md from
        // live-accumulated segments so the user has SOMETHING the
        // moment they hit Stop. Now we overwrite it with the polished
        // version. Render + write run as a tight synchronous pair
        // (no await in between) so MainActor scheduling guarantees no
        // other task can mutate `segments` while we're snapshotting.
        let reRenderState = signposter.beginInterval("re_render_md", id: signposter.makeSignpostID())
        let t_reRender = Date()
        let md = MarkdownExporter.renderMarkdown(session: self)
        signposter.endInterval("re_render_md", reRenderState)
        log.info("post-stop re_render_md: \(ms(t_reRender), privacy: .public)ms, \(md.count, privacy: .public) bytes")

        let reWriteState = signposter.beginInterval("re_write_md", id: signposter.makeSignpostID())
        let t_reWrite = Date()
        let mdURL = directory.appendingPathComponent("transcript.md")
        do {
            try md.write(to: mdURL, atomically: true, encoding: .utf8)
        } catch {
            // Don't toast on re-write failure — the user already has
            // the live-quality transcript.md from stop(), so this is
            // a quality regression rather than data loss. Logged so
            // the next `log show` pass catches it.
            log.error("Failed to re-write transcript.md: \(error.localizedDescription, privacy: .public)")
        }
        signposter.endInterval("re_write_md", reWriteState)
        log.info("post-stop re_write_md: \(ms(t_reWrite), privacy: .public)ms")

        // Refresh History so any opened SessionDetailView re-reads
        // the freshly-written final-quality transcript instead of
        // sticking with the live snapshot it loaded a few seconds ago.
        await SessionStore.shared.refresh()

        if Task.isCancelled || sessionDirectory?.lastPathComponent != sessionID {
            await bailRotated(stage: "after re-render")
            return
        }

        // ── Stage 4: Summary (if requested) ──────────────────────────
        //
        // The summarizer takes the final-quality transcript text —
        // built from the same `segments` array we just rendered to
        // disk — and produces a structured MeetingSummary. The pre-
        // 1.0.7.3 path snapshotted `transcript` BEFORE the final
        // Whisper pass landed, which meant the LLM saw live-quality
        // segments while the on-disk transcript.md had final-quality
        // ones. Now both share the same source.
        var summary: MeetingSummary? = nil
        if willSummarize {
            let transcriptText = fullTranscriptText
            let summarizeState = signposter.beginInterval("summarize", id: signposter.makeSignpostID())
            let t_summarize = Date()
            summary = await summarizer.summarize(
                transcript: transcriptText,
                title: title,
                localeHint: localeHint
            )
            signposter.endInterval("summarize", summarizeState)
            log.info("post-stop summarize: \(ms(t_summarize), privacy: .public)ms, transcript=\(transcriptText.count, privacy: .public) bytes, summary=\(summary != nil ? "ok" : "nil", privacy: .public)")

            if Task.isCancelled {
                summaryGenerationState = .failed("cancelled")
                await SessionStore.shared.finishGenerating(sessionID)
                if generation == summaryTaskGeneration {
                    summaryTask = nil
                }
                return
            }

            if let summary {
                let writeState = signposter.beginInterval("write_summary", id: signposter.makeSignpostID())
                let t_writeSummary = Date()
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
                log.info("post-stop write_summary: \(ms(t_writeSummary), privacy: .public)ms")
            }
        }

        // ── Stage 5: Auto-send to downstream destinations ────────────
        //
        // If a fresh recording has begun in the meantime (reset()
        // ran), instance state has rotated and autoSend would push
        // the WRONG session to Notion/MCP. Skip — user can resend
        // manually from History.
        if Task.isCancelled || sessionDirectory?.lastPathComponent != sessionID {
            await bailRotated(stage: "before auto_send")
            return
        }

        let autoSendState = signposter.beginInterval("auto_send", id: signposter.makeSignpostID())
        let t_autoSend = Date()
        await runAutoSendDestinations()
        signposter.endInterval("auto_send", autoSendState)
        log.info("post-stop auto_send: \(ms(t_autoSend), privacy: .public)ms")

        // ── Stage 6: Audio purge if delete-after-transcription ───────
        //
        // Pipeline is done with the audio (transcript + summary
        // landed on disk, downstream destinations have shipped).
        // Delete-after-transcription mode kicks in here: drop the
        // raw .caf for THIS session immediately.
        //
        // Gating: for the summary path we wait for summary success
        // (so the user can re-summarize from SessionDetailView if it
        // failed). For the no-summary path (voice notes, autoSummarize
        // disabled, provider unavailable) we purge unconditionally —
        // there's no second-chance LLM pass to keep audio around for,
        // and transcript.md is final-quality by this point.
        let canPurge = willSummarize ? (summary != nil) : true
        if canPurge,
           settings.audioRetentionDays == AppSettings.audioRetentionDeleteAfterTranscription {
            AudioRetentionSweep.purgeOneSession(at: directory)
        }

        // Final state flip. The no-summary path never called
        // beginGenerating, so finishGenerating would no-op — skip it
        // entirely to keep the trace clean.
        if willSummarize {
            summaryGenerationState = (summary != nil) ? .ready : .failed("no summary")
            await SessionStore.shared.finishGenerating(sessionID)
        }
        // Same generation guard as bailRotated — see `summaryTaskGeneration`
        // doc for the race we're protecting against.
        if generation == summaryTaskGeneration {
            summaryTask = nil
        }
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
            tag: tag,
            systemAudioStatus: systemAudioStatusValue
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
    private func failFast(_ message: String) async {
        log.error("Session start failed: \(message, privacy: .public)")
        releaseSessionsFolderTicket()
        micTranscriber.reset()
        systemTranscriber.reset()
        // recorder/systemAudio may not have started yet on early
        // paths (Whisper-failed branches) — reset is idempotent.
        recorder.reset()
        // Was: `Task { await systemAudio.stop() }` — unawaited race
        // with the next start(). If the user immediately retried
        // (e.g. after a "Whisper not ready yet" early-exit), the
        // next systemAudio.start() could run before this stop() had
        // finished, leaving SCStream in an inconsistent "starting
        // over an already-starting stream" state. Build 40 fix per
        // macOS audit: make failFast() async + await the stop so
        // the next start() always sees a clean slate.
        await systemAudio.stop()
        screenshots.stop()
        silenceMonitor.stop()
        cancelAutoStop()
        removeThermalDowngrade()
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
            tag: tag,
            systemAudioStatus: systemAudioStatusValue
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
        tag: String = "",
        systemAudioStatus: String? = nil
    ) -> StoredSession {
        let transcriptText = segments
            .map { "\($0.text)" }
            .joined(separator: " ")
        let preview = String(transcriptText.prefix(220))
        let transcriptURL = directory.appendingPathComponent("transcript.md")
        let micURL = directory.appendingPathComponent("microphone.caf")
        let systemURL = directory.appendingPathComponent("system_audio.caf")
        // Read centroid IDs from the sidecar speakers.json if it
        // exists — same path SessionStore.refresh uses. Lets the
        // "session only" UI flag in SessionDetailView work for
        // sessions surfaced through this in-memory builder (post-
        // stop MCP auto-send and the manual Send-to snapshot path).
        // Empty Set is fine when the file is absent or unreadable;
        // SessionDetailView treats missing == "all session-only".
        let centroidIDs: Set<String> = {
            let url = directory.appendingPathComponent("speakers.json")
            guard let data = try? Data(contentsOf: url),
                  let file = try? JSONDecoder().decode(SpeakerCentroidsFile.self, from: data) else {
                return []
            }
            return Set(file.centroids.keys)
        }()
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
            tag: tag,
            meetingAttendees: [],
            // In-memory builder (post-stop MCP auto-send + manual
            // Send-to snapshot) — the bound calendar event title
            // is available off the live RecordingSession, but the
            // function is `static` and doesn't carry it through.
            // Passing nil is the safe default; SessionStore.refresh
            // will re-read frontmatter on the next library scan and
            // pick up the title from disk.
            linkedEventTitle: nil,
            speakerMap: [:],
            speakerCentroidIDs: centroidIDs,
            systemAudioStatus: systemAudioStatus
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

    // MARK: - Thermal / low-power auto-downgrade

    /// Watch thermal state + Low Power Mode while a Full-tier session runs
    /// and silently drop live transcription Full→Lite under pressure,
    /// auto-restoring when it clears. The final pass on Stop stays full
    /// quality and the user's saved tier is never modified (runtime override).
    private func installThermalDowngrade(startedTier: LiveTranscriptionTier) {
        removeThermalDowngrade()
        startedLiveTier = startedTier
        // Only Full sessions have headroom to shed; Lite/Off/Apple are
        // already light. (Dictation forces Full but is short — harmless.)
        guard startedTier == .full else { return }
        let nc = NotificationCenter.default
        thermalObserver = nc.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.evaluateThermalDowngrade() }
        }
        powerObserver = nc.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.evaluateThermalDowngrade() }
        }
        // Evaluate immediately in case we START already hot / in Low Power Mode.
        evaluateThermalDowngrade()
    }

    private func removeThermalDowngrade() {
        if let t = thermalObserver { NotificationCenter.default.removeObserver(t); thermalObserver = nil }
        if let p = powerObserver { NotificationCenter.default.removeObserver(p); powerObserver = nil }
        thermalDowngradeActive = false
    }

    private func evaluateThermalDowngrade() {
        guard status == .recording, startedLiveTier == .full else { return }
        let info = ProcessInfo.processInfo
        let hot = info.thermalState == .serious || info.thermalState == .critical
        let shouldThrottle = hot || info.isLowPowerModeEnabled
        if shouldThrottle, !thermalDowngradeActive {
            thermalDowngradeActive = true
            micTranscriber.setLiveTier(.lite)
            systemTranscriber.setLiveTier(.lite)
            log.info("Live transcription auto-downgraded Full→Lite (\(hot ? "thermal" : "low-power", privacy: .public))")
            ToastCenter.shared.show(
                "High \(hot ? "heat" : "power") load — live transcript eased to Lite. The final transcript on Stop stays full quality.",
                style: .info
            )
        } else if !shouldThrottle, thermalDowngradeActive {
            thermalDowngradeActive = false
            micTranscriber.setLiveTier(startedLiveTier)
            systemTranscriber.setLiveTier(startedLiveTier)
            log.info("Live transcription auto-restored to Full (load normalised)")
            ToastCenter.shared.show("Load eased — live transcript back to Full.", style: .info)
        }
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
        removeThermalDowngrade()
        releaseSessionsFolderTicket()
        summarizer.clear()
        sessionDirectory = nil
        micArchiveURL = nil
        systemArchiveURL = nil
        startedAt = nil
        boundMeeting = nil
        // Tester bug 2026-05-25: a calendar-bound meeting (title set
        // to the event name, e.g. "Pilik's Birthday") completed days
        // earlier, the session was saved, and `title` lived on in
        // memory. Two days later a voice-note hotkey hit triggered a
        // new session — reset() cleared boundMeeting/folder/currentMode
        // but NOT title. start() checked `if title.isEmpty` to decide
        // whether to regenerate, found it non-empty, and the voice
        // note was saved under "Pilik's Birthday". Cleared here so
        // the regeneration path in start() always runs from a clean
        // slate. The `pendingBoundMeeting` flow in `bindToMeeting`
        // re-sets the title from `meeting.title` AFTER reset() — same
        // pattern as boundMeeting / folder / mode pending fields —
        // so calendar-driven sessions still inherit the event name.
        title = ""
        folder = .inbox
        tag = ""
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
    /// stayed silent (usually BT output, or the macOS 26 SCStream
    /// regression) OR was never armed.
    var hasCapturedSystemAudio: Bool {
        systemAudio.hasReceivedAudio
    }

    // MARK: - Archive truncation audit (1.0.7.1)

    /// Minimum on-disk byte count for a CAF file to be considered
    /// "has actual audio data". CAF header + format/data chunk
    /// metadata is typically 100-200 bytes; we use a comfortable
    /// 4 KB threshold so a file that's just chunk-headers-and-nothing
    /// gets correctly classified as truncated. Picked conservatively
    /// — even a 1-second mono float32 capture at 16 kHz is 64 KB,
    /// well above this floor.
    private static let archiveDataFloorBytes: Int64 = 4096

    /// Render-thread write-error tolerance before flipping captured →
    /// truncated. A few transient errors (disk pressure, momentary
    /// device handover) are tolerable; >25 means systemic failure
    /// and the file is almost certainly partial. Matches the toast
    /// threshold the recorder uses for its post-stop summary
    /// (CoreAudioMicRecorder.stop() `if errCount > 25`).
    private static let archiveWriteErrorTolerance: Int = 25

    /// Read on-disk byte count for an archive URL. Returns 0 for
    /// missing file (FileManager throws → treat as nothing on disk).
    /// Synchronous file-system stat — only called once per stream
    /// Free bytes on the volume backing `url` — "important usage" capacity,
    /// which counts purgeable space, so we don't drop to transcript-only on a
    /// disk macOS could free on demand. nil if unqueryable; callers treat nil
    /// as "plenty".
    private static func freeDiskBytes(at url: URL?) -> Int64? {
        guard let url else { return nil }
        return (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    /// per stop(), not in a hot loop.
    private static func archiveBytesOnDisk(_ url: URL?) -> Int64 {
        guard let url else { return 0 }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Post-stop audit of the system-audio archive. See `ArchiveStatus`
    /// docs for the four states and the failure mode each one names.
    /// Called from `stop()` after Final pass + from `MarkdownExporter`
    /// for the frontmatter line. Idempotent and side-effect-free —
    /// only reads counters + file size.
    var systemAudioArchiveStatus: ArchiveStatus {
        guard settings.captureSystemAudio, currentMode == .meeting else {
            return .off
        }
        let bytes = Self.archiveBytesOnDisk(systemArchiveURL)
        let receivedAnything = systemAudio.hasReceivedAudio
        let receivedAudible = systemAudio.receivedAudibleAudio
        let framesWritten = systemAudio.archivedFrameCount
        let (errCount, _) = systemAudio.archiveWriteErrorsSummary

        if !receivedAnything {
            // SCKit never delivered a buffer. Same case the existing
            // silenceMonitor surfaces mid-recording.
            return .empty
        }
        // Buffers arrived but EVERY one was silence (DRM-protected
        // playback, or the macOS Tahoe all-zero-buffer glitch). The file
        // can be non-trivial in size — silence still writes frames — but
        // it holds no remote audio, so report `.empty`, not `.captured`,
        // and let the frontmatter + post-stop toast tell the truth.
        if !receivedAudible {
            return .empty
        }
        // Buffer(s) arrived. Now check whether ANY of them landed on
        // disk. Three truncation paths:
        //   1. File is missing or below the data floor — open failed
        //      silently, or every write threw before the writer
        //      could grow the data chunk beyond headers.
        //   2. Frames-written counter is zero despite hasReceivedAudio
        //      — open succeeded but every write throw triggered the
        //      catch branch. The Billions 2026-05-25 failure mode.
        //   3. Write errors above tolerance — even if some frames
        //      landed, the file is so partial that the user needs
        //      to know before they try to re-summarize.
        if bytes < Self.archiveDataFloorBytes
            || framesWritten == 0
            || errCount > Self.archiveWriteErrorTolerance
        {
            return .truncated(
                bytes: bytes,
                framesWritten: framesWritten,
                writeErrors: errCount
            )
        }
        return .captured(bytes: bytes)
    }

    /// Post-stop audit of the microphone archive. Symmetric to
    /// `systemAudioArchiveStatus` — mic almost always exists in
    /// meeting/voiceNote/dictation modes; `.off` is mostly a future
    /// hook for hypothetical mic-disabled modes.
    var micAudioArchiveStatus: ArchiveStatus {
        // Mic is always recorded in all three modes (meeting, voice
        // note, dictation). There's no setting to disable it — the
        // recorder is the entire point. So the .off case is reserved
        // for the no-permission early-return path; we surface it as
        // "empty" instead here, since "no permission to record mic"
        // is a real failure the user should know about.
        let bytes = Self.archiveBytesOnDisk(micArchiveURL)
        let framesWritten = recorder.archivedFrameCount
        let (errCount, _) = recorder.archiveWriteErrorsSummary
        let receivedAnything = framesWritten > 0 || bytes > 0

        if !receivedAnything {
            return .empty
        }
        if bytes < Self.archiveDataFloorBytes
            || framesWritten == 0
            || errCount > Self.archiveWriteErrorTolerance
        {
            return .truncated(
                bytes: bytes,
                framesWritten: framesWritten,
                writeErrors: errCount
            )
        }
        return .captured(bytes: bytes)
    }

    /// Convenience: the same three-state status MarkdownExporter
    /// writes to `daisy_system_audio_status:` frontmatter, surfaced
    /// here so the in-process `StoredSession` snapshots used by
    /// auto-send and Send-to carry the same flag. `"ok"` /
    /// `"empty"` / `nil` (capture was off, no opinion to record).
    var systemAudioStatusValue: String? {
        guard settings.captureSystemAudio else { return nil }
        return systemAudio.hasReceivedAudio ? "ok" : "empty"
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
