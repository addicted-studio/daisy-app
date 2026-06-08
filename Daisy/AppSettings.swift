//
//  AppSettings.swift
//  Daisy
//
//  User-facing preferences backed by UserDefaults (non-secret) and
//  Keychain (Notion token + parent id). Observable so the UI updates
//  when values change.
//

import Foundation
import Observation
import os

@Observable
@MainActor
final class AppSettings {
    // Non-secret prefs.
    var captureSystemAudio: Bool {
        didSet { defaults.set(captureSystemAudio, forKey: Self.k_captureSystemAudio) }
    }

    /// Persistent UID of the user-picked microphone, or empty string
    /// to follow the macOS system default (the legacy v1.0 behaviour).
    /// We store UID rather than `AudioDeviceID` because UID is stable
    /// across reboots and reconnects; `AudioDeviceID` is not.
    /// `CoreAudioMicRecorder` resolves UID → live `AudioDeviceID` at
    /// every recording start, and silently falls back to system default
    /// if the saved device is gone (unplugged headset, removed USB
    /// interface, etc.).
    var selectedMicDeviceUID: String {
        didSet { defaults.set(selectedMicDeviceUID, forKey: Self.k_selectedMicDeviceUID) }
    }

    var screenshotsEnabled: Bool {
        didSet { defaults.set(screenshotsEnabled, forKey: Self.k_screenshotsEnabled) }
    }
    var screenshotIntervalSec: Int {
        didSet { defaults.set(screenshotIntervalSec, forKey: Self.k_screenshotInterval) }
    }
    var autoSummarize: Bool {
        didSet { defaults.set(autoSummarize, forKey: Self.k_autoSummarize) }
    }

    /// Language the summary itself is written in. Decoupled from
    /// the transcript locale because users often record meetings in
    /// one language but want the summary in another (e.g. record RU,
    /// summarise EN for a partner who'll read the notes).
    ///
    /// Stored as the value of `SummaryLanguage.id`. "auto" means
    /// "use the transcript's language" — the historical behaviour.
    var summaryLanguage: String {
        didSet { defaults.set(summaryLanguage, forKey: Self.k_summaryLanguage) }
    }

    /// Default transcription locale applied to every new session
    /// at creation time. Same string contract as
    /// `Transcriber.availableLocales` — "auto" means
    /// `NLLanguageRecognizer`-driven auto-detect on first
    /// transcript chunks; otherwise a two-letter ISO code locks
    /// Whisper to that language. Stored separately from the
    /// per-session `localeIdentifier` so users with stable
    /// recording habits (always RU, always EN) don't have to
    /// re-pick on every session.
    var defaultTranscriptionLocale: String {
        didSet { defaults.set(defaultTranscriptionLocale, forKey: Self.k_defaultTranscriptionLocale) }
    }

    /// Voice-note mode override for transcription locale. Empty
    /// string means "use `defaultTranscriptionLocale`" (the
    /// meeting default). Non-empty overrides per-mode — useful
    /// when the user records meetings in English but dictates
    /// personal notes in Russian (or vice versa).
    var voiceNoteLocale: String {
        didSet { defaults.set(voiceNoteLocale, forKey: Self.k_voiceNoteLocale) }
    }

    /// Dictation mode override for transcription locale. Same
    /// contract as `voiceNoteLocale` — empty falls back to the
    /// meeting default. Defaults to empty so behaviour is
    /// backwards-compatible for users who haven't picked yet.
    var dictationLocale: String {
        didSet { defaults.set(dictationLocale, forKey: Self.k_dictationLocale) }
    }

    /// EXPERIMENTAL: use Parakeet (FluidAudio, on-device) instead of
    /// Whisper for the DICTATION final pass. Streaming transducer on the
    /// Neural Engine — much lower decode latency; multilingual incl. RU.
    /// Default off — ships dark for A/B. Flip via:
    ///   defaults write app.essazanov.Daisy daisy.dictationUseParakeet -bool YES
    /// First enable triggers a one-time ~600 MB model download. Falls back
    /// to Whisper automatically on error / empty / very short clips. See
    /// research note 2026-06-04-dictation-latency-optimization.
    var dictationUseParakeet: Bool {
        didSet { defaults.set(dictationUseParakeet, forKey: Self.k_dictationUseParakeet) }
    }

    /// EXPERIMENTAL: stream the DICTATION live preview through FluidAudio's
    /// Nemotron 3.5 multilingual streaming ASR (560 ms chunks, Neural
    /// Engine) instead of the Whisper rolling-window pass. Preview-only —
    /// the pasted text still comes from Whisper/Parakeet on release.
    /// Default off — ships dark for A/B (same playbook as Parakeet). Flip:
    ///   defaults write app.essazanov.Daisy daisy.dictationUseNemotronLive -bool YES
    /// First enable triggers a one-time model download (multilingual
    /// 560 ms variant). See NemotronLiveEngine.
    var dictationUseNemotronLive: Bool {
        didSet { defaults.set(dictationUseNemotronLive, forKey: Self.k_dictationUseNemotronLive) }
    }

    /// Global meeting-recorder hotkey (mode = .meeting). `.none`
    /// disables. Stored in UserDefaults as JSON (struct, not enum
    /// any more). This is the original Daisy hotkey from 1.0.x.
    var recordHotkey: HotkeyChoice {
        didSet {
            if let data = try? JSONEncoder().encode(recordHotkey) {
                defaults.set(data, forKey: Self.k_recordHotkey)
            }
        }
    }

    /// Voice-notes hotkey (mode = .voiceNote). Starts a quick
    /// personal recording with no LLM summary and routes the
    /// session into the Notes folder. Toggle on/off; same UX as
    /// `recordHotkey` but for the lighter "I want to capture this
    /// thought before I forget" flow. `.none` disables.
    var voiceNoteHotkey: HotkeyChoice {
        didSet {
            if let data = try? JSONEncoder().encode(voiceNoteHotkey) {
                defaults.set(data, forKey: Self.k_voiceNoteHotkey)
            }
        }
    }

    /// Dictation hotkey (mode = .dictation). Wispr-Flow-lite: hold
    /// to record, release to transcribe → put on the clipboard +
    /// fire a toast prompting Cmd+V. No session is saved, no LLM
    /// summary runs. `.none` disables. Same JSON storage as the
    /// other two hotkeys.
    var dictationHotkey: HotkeyChoice {
        didSet {
            if let data = try? JSONEncoder().encode(dictationHotkey) {
                defaults.set(data, forKey: Self.k_dictationHotkey)
            }
        }
    }

    /// When ON, Daisy auto-starts a recording the moment one of the
    /// known meeting apps (Zoom / Teams / Telegram / etc.) launches.
    ///
    /// As of 1.0.7.9 this is no longer a directly user-facing toggle —
    /// it's a derived wiring flag written through by `autoStartPolicy`'s
    /// `didSet`. The Settings UI exposes the 4-mode policy instead; this
    /// bool (and `autoStartFromCalendar`) remain the substrate that
    /// `ServiceWiring.applyMeetingAutoStart` / `applyCalendar` and the
    /// MainView `.onChange` re-wiring read, so the existing detection
    /// plumbing keeps working untouched. Kept persisted so a downgrade
    /// to a pre-policy build still finds a sane value.
    var autoStartOnMeeting: Bool {
        didSet { defaults.set(autoStartOnMeeting, forKey: Self.k_autoStartOnMeeting) }
    }

    /// Granular auto-start policy (Talat-parity), the single user-facing
    /// control in Settings → Meetings. Supersedes the old pair of
    /// independent "Start when a meeting app opens" / "Start at the
    /// scheduled meeting time" toggles with one segmented control:
    ///
    ///   • **Always**    — auto-record every detected call (both the
    ///     NSWorkspace app-launch detector AND the calendar detector
    ///     fire, and each starts recording immediately).
    ///   • **Selective** — auto-record only calendar-synced meetings
    ///     (events that carry a Zoom/Meet/Teams/Webex link). The
    ///     app-launch detector is suppressed, so opening Zoom for a
    ///     personal call you didn't schedule won't be captured. This is
    ///     the simplest sensible "allowlist" that fits Daisy — the
    ///     calendar IS the allowlist. (A per-app allowlist was judged
    ///     too heavy for this surface; noted in the 1.0.7.9 work.)
    ///   • **Prompt**    — detect the call and ASK first via a macOS
    ///     banner with Record / Ignore actions, instead of starting
    ///     silently. Applies to BOTH detectors.
    ///   • **Manual**    — never auto-start; only the Record button /
    ///     hotkey starts a session.
    ///
    /// `didSet` writes through to the legacy `autoStartOnMeeting` /
    /// `autoStartFromCalendar` substrate flags + the `autoStartPromptMode`
    /// flag, so all existing wiring (`ServiceWiring`, the MainView
    /// `.onChange` handlers, `CalendarService.tick`) keeps functioning
    /// with no structural change. The mapping:
    ///   Always    → app-launch ON,  calendar ON,  prompt OFF
    ///   Selective → app-launch OFF, calendar ON,  prompt OFF
    ///   Prompt    → app-launch ON,  calendar ON,  prompt ON
    ///   Manual    → app-launch OFF, calendar OFF, prompt OFF
    var autoStartPolicy: AutoStartPolicy {
        didSet {
            defaults.set(autoStartPolicy.rawValue, forKey: Self.k_autoStartPolicy)
            applyAutoStartPolicyToSubstrate()
        }
    }

    /// Derived from `autoStartPolicy` (set ON only when policy is
    /// `.prompt`). When true, the detection paths — calendar
    /// (`RecordingSession.startFromMeeting`) and app-launch
    /// (`ServiceWiring.applyMeetingAutoStart`) — surface a Record /
    /// Ignore banner instead of starting the recording directly. Stored
    /// so a process restart preserves the choice without re-deriving
    /// (the policy `didSet` also keeps it in sync).
    var autoStartPromptMode: Bool {
        didSet { defaults.set(autoStartPromptMode, forKey: Self.k_autoStartPromptMode) }
    }

    /// Transient (not persisted): true iff `autoStartPolicy` was loaded
    /// from an explicit stored value at init, vs. derived from the
    /// legacy bools. Gates the one-shot end-of-init substrate reconcile
    /// so we only let the policy overwrite the bools when the user has
    /// actually adopted the new control — never on the legacy path,
    /// where flipping a bool would change behaviour (e.g. an app-launch-
    /// only legacy user must NOT get calendar auto-start turned on).
    @ObservationIgnored
    private var didLoadStoredAutoStartPolicy: Bool = false

    /// When ON, finishing a session (Stop) automatically opens the
    /// just-recorded session in History so the transcript is visible
    /// immediately, and the summary section pops in once the LLM
    /// returns. Default OFF — Daisy stays in the background by
    /// default; users who want the Granola-style "session window
    /// pops up after every meeting" flow flip this on.
    var showSessionAfterStop: Bool {
        didSet { defaults.set(showSessionAfterStop, forKey: Self.k_showSessionAfterStop) }
    }

    /// When ON, Daisy posts a "Are we done?" macOS banner after a
    /// long stretch of silence during recording (3 min) or a long
    /// pause (5 min). OFF disables the prompt entirely — the
    /// SilenceMonitor still tracks state internally (cheap), it
    /// just never surfaces a banner.
    var silencePromptsEnabled: Bool {
        didSet { defaults.set(silencePromptsEnabled, forKey: Self.k_silencePromptsEnabled) }
    }

    /// When ON (default), Daisy posts a macOS banner the moment the
    /// calendar-driven auto-start fires. Includes a "Stop & save"
    /// action so the user can bail out if Daisy picked up a meeting
    /// they didn't want recorded.
    var notifyOnAutoStart: Bool {
        didSet { defaults.set(notifyOnAutoStart, forKey: Self.k_notifyOnAutoStart) }
    }

    /// When ON (default), Daisy posts a confirmation banner when the
    /// calendar-driven auto-stop fires and the recording is saved.
    var notifyOnAutoStop: Bool {
        didSet { defaults.set(notifyOnAutoStop, forKey: Self.k_notifyOnAutoStop) }
    }

    /// When ON, the diarization pass also runs over the microphone
    /// stream — useful when remote-meeting participants are heard
    /// through the user's speakers (in-room playback) instead of
    /// being captured separately via system-audio loopback. Mic-side
    /// segments then get "Speaker A / B / C" labels instead of all
    /// collapsing into "Me". OFF by default — adds Pyannote inference
    /// over the full mic recording (CoreML, neural-engine, ~15-25%
    /// of Whisper runtime), so for the common one-user case it's
    /// wasted compute.
    var diarizeMicrophone: Bool {
        didSet { defaults.set(diarizeMicrophone, forKey: Self.k_diarizeMicrophone) }
    }

    /// When ON (default), Whisper transcribes audio in rolling 2-second
    /// passes WHILE the meeting is happening, so the user sees segments
    /// appear in the toolbar popover in near-real-time. When OFF,
    /// Whisper is silent during recording — only the audio archive
    /// gets written to disk; transcription runs as a single pass on
    /// Stop. Off-mode is dramatically lighter on the MainActor (no
    /// per-window commits + cache invalidations + SwiftUI cascades),
    /// which makes long sessions feel snappier and pause/resume
    /// react instantly even on 1.5h+ recordings. Trade-off: no live
    /// transcript view during the meeting. Build 43 added this as
    /// an opt-in perf escape hatch after Egor's hypothesis: "может
    /// можно сделать так что бы не сразу превращать в текст и так
    /// будет легче?" — yes, materially.
    ///
    /// Future direction: this may become default OFF for ≥macOS 26
    /// where MainActor saturation under the new SwiftUI Observable
    /// system is more pronounced. For now default ON keeps the
    /// behaviour everyone's used to.
    var liveTranscriptionTier: LiveTranscriptionTier {
        didSet { defaults.set(liveTranscriptionTier.rawValue, forKey: Self.k_liveTranscriptionTier) }
    }

    /// Speakers mode for the system-audio stream. When `true` (default,
    /// behaviour up to 1.0.6.x), pyannote diarizes the remote stream
    /// into Bobby / Wags / Faraday / etc — one label per detected
    /// voice cluster. When `false` ("Two sides" / Granola-style),
    /// the remote diarizer is disabled entirely and every system-audio
    /// segment gets a single "Remote" label. The latter is useful
    /// when:
    ///   • Meeting has rapid back-and-forth or similar-sounding voices
    ///     where the auto-detector over-splits clusters (4 actual
    ///     speakers → 5+ labels with gaps like A / B / D / F / G)
    ///   • User just wants the simpler "you vs them" output and
    ///     doesn't care which remote spoke
    ///   • Faster post-stop (skips pyannote on system stream)
    /// The mic stream is unaffected — it's still labeled with
    /// `userDisplayName` or "Me".
    var diarizeRemoteSpeakers: Bool {
        didSet { defaults.set(diarizeRemoteSpeakers, forKey: Self.k_diarizeRemoteSpeakers) }
    }

    /// EXPERIMENTAL (default OFF). When ON and a recording is bound to a
    /// calendar event, Daisy pins the remote diarizer to the attendee
    /// count (minus you) as a hard `numClusters` hint instead of auto-
    /// detect. Can sharpen diarization when the invite is accurate, but a
    /// wrong count (no-shows, uninvited joiners, one person on two devices)
    /// can make it worse — hence opt-in, pending on-device A/B. No UI
    /// toggle yet; flip via defaults for testing.
    var diarizeUseAttendeeCountHint: Bool {
        didSet { defaults.set(diarizeUseAttendeeCountHint, forKey: Self.k_diarizeUseAttendeeCountHint) }
    }

    /// Post-merge dedup pass for acoustic loopback. When ON (default),
    /// after both mic and system transcribers finish, the merge step
    /// walks every mic-side segment and drops it if a system-side
    /// segment within ±2s has matching text (normalized Levenshtein
    /// similarity >0.8, ±20% length). Targets the case where the user
    /// plays meeting audio through speakers instead of headphones:
    /// the mic picks up the same audio and Whisper transcribes it
    /// twice. Sequential matches (3+ consecutive) are treated as
    /// confirmed echo. Isolated single matches are kept on the
    /// assumption that the user might be quoting what the other
    /// person said. Set OFF only if you need every mic segment
    /// preserved (e.g., diagnostic / archival use cases) and accept
    /// the duplicate-attribution noise.
    var suppressAcousticEcho: Bool {
        didSet { defaults.set(suppressAcousticEcho, forKey: Self.k_suppressAcousticEcho) }
    }

    /// Post-stop global speaker re-clustering. When ON (default), once
    /// the post-stop pipeline writes transcript + summary, a final
    /// async pass loads the full concatenated audio off disk and
    /// re-runs pyannote diarization with global context (the live
    /// path only sees streaming 10-30s chunks, so the same voice
    /// can fragment into Remote A / Remote D / Remote G across
    /// chunks). The re-clustered labels are mapped back to the live
    /// transcript by IoU overlap so user-applied speaker names
    /// (Remote A → Алиса) survive. Adds 30-90s of background work
    /// for typical meetings; user-visible state stays in `.finished`
    /// throughout. Set OFF for the fastest possible Stop & save and
    /// accept that some speakers may fragment.
    var globalReclusterAfterStop: Bool {
        didSet { defaults.set(globalReclusterAfterStop, forKey: Self.k_globalReclusterAfterStop) }
    }

    /// Display name used for the user's own voice in transcripts.
    /// Empty (default) → falls back to the legacy "Me" label.
    /// When set, mic-source segments render as `[Egor]` instead of
    /// `[Me]` in the live transcript UI, the saved transcript.md
    /// frontmatter body, AND the LLM prompt — giving the summarizer
    /// concrete identity for sentences like "Maria asked Egor about
    /// pricing" instead of a generic first-person placeholder.
    var userDisplayName: String {
        didSet { defaults.set(userDisplayName, forKey: Self.k_userDisplayName) }
    }

    /// How cross-meeting speaker recognition behaves once Daisy has a
    /// known speaker (voice fingerprint and/or email) that matches a
    /// new session. Three modes (Talat-parity, 1.0.7.10):
    ///   • `.automatic` (DEFAULT) — apply the match silently, pre-
    ///     filling the transcript's speaker map. This is the behaviour
    ///     of every build before 1.0.7.10, kept as default so existing
    ///     users see NO change (Talat itself defaults to Suggest, but
    ///     we don't silently downgrade an experience people already
    ///     rely on).
    ///   • `.suggest` — compute the match but DON'T apply it; surface
    ///     it as a confirmable suggestion (post-stop notification +
    ///     a Confirm affordance in the session's Name-the-speakers
    ///     card) so the user approves before names land in the
    ///     transcript.
    ///   • `.off` — no cross-meeting auto-match at all; speakers stay
    ///     "Remote A/B/C" until the user names them by hand. The
    ///     voice fingerprint is still persisted on manual naming
    ///     (so turning this back on later works), just never auto-
    ///     applied. Per-session `speakers.json` is written regardless.
    /// Note: this gates the AUTO-LABEL step only. The underlying voice-
    /// match engine (`SpeakerProfileStore.findMatch`) is unchanged.
    var speakerMatchMode: SpeakerMatchMode {
        didSet { defaults.set(speakerMatchMode.rawValue, forKey: Self.k_speakerMatchMode) }
    }

    /// Days to keep raw audio (.caf) files for finished sessions.
    /// Tag conventions:
    ///   • `audioRetentionDeleteAfterTranscription` (-1) — fresh-
    ///     install default since 1.0.6.12. Audio purges per-session
    ///     immediately after `finalizePostStop` lands transcript +
    ///     summary on disk. No timer sweep involved. Matches the
    ///     "audio doesn't outlive the pipeline" privacy posture
    ///     Granola made the table-stakes in this category.
    ///   • `0` — keep forever. Default for users upgrading from
    ///     pre-1.0.6.12 builds who never opened Settings → Storage.
    ///   • positive N — keep N days, then sweep at app launch
    ///     (`AudioRetentionSweep.runIfNeeded`). Existing 1/7/30
    ///     picks preserve their semantic.
    /// In all modes, transcript.md / summary.json / speakers.json /
    /// screenshots stay intact — only raw `.caf` archives are
    /// purged.
    var audioRetentionDays: Int {
        didSet { defaults.set(audioRetentionDays, forKey: Self.k_audioRetentionDays) }
    }

    /// Sentinel value for `audioRetentionDays` meaning "delete the
    /// raw audio as soon as Daisy is done with it (post-transcript +
    /// summary)". Negative so it never collides with a real day
    /// count, both forward and backward. Constant exposed publicly
    /// so callers (RecordingSession, SettingsView, AudioRetentionSweep)
    /// don't magic-number the -1.
    static let audioRetentionDeleteAfterTranscription: Int = -1

    /// Sentinel value for `audioRetentionDays` meaning "don't write
    /// audio to disk at all" (build 44). The strongest privacy
    /// posture in the picker — Whisper still consumes from the live
    /// in-memory PCM stream (AsyncStream from the tap closure), so
    /// the transcript is unaffected; only the on-disk `.caf` archive
    /// is skipped. RecordingSession reads this constant and passes
    /// `archiveURL: nil` to `recorder.start()` and
    /// `systemAudio.start()`. Trade-off: no crash-recovery from
    /// disk (if Daisy crashes mid-meeting the transcript is lost),
    /// no re-transcription with a different Whisper model later.
    /// Matches the "transcription only" mode Fireflies / Read.ai /
    /// Wispr Flow ship as a compliance / privacy escape hatch.
    static let audioRetentionDoNotRecord: Int = -2

    /// When ON, Daisy plays a short macOS system sound on recording
    /// transitions (start / pause / resume / stop). Off for users
    /// who record in environments where the click would be picked
    /// up by their own mic or who just don't like audio chrome.
    /// Default ON because the cues are quiet (~0.4 volume) and
    /// the feedback materially helps remind a user the session is
    /// live when the floating widget isn't visible.
    var recordingSoundsEnabled: Bool {
        didSet { defaults.set(recordingSoundsEnabled, forKey: Self.k_recordingSoundsEnabled) }
    }

    /// When ON, Daisy's menu-bar item shows the next upcoming
    /// calendar event next to its icon ("14:30 · Q3 Review") so the
    /// user can glance at it without opening Daisy. Off by default —
    /// adds chrome to the menu bar that some users don't want.
    /// Suppressed while recording (recording state takes priority).
    var menuBarShowsNextMeeting: Bool {
        didSet { defaults.set(menuBarShowsNextMeeting, forKey: Self.k_menuBarShowsNextMeeting) }
    }

    /// Whether the first-run welcome sheet has been dismissed at
    /// least once. We show it on first launch (and on a clean
    /// install with no other Daisy data) to anchor the user on
    /// where the important Settings live — provider setup, Notion,
    /// activation triggers. Default false; flipped to true the
    /// moment the user closes the sheet.
    var hasShownFirstRun: Bool {
        didSet { defaults.set(hasShownFirstRun, forKey: Self.k_hasShownFirstRun) }
    }

    /// Set the first time a user opens a meeting session whose
    /// `daisy_system_audio_status` is `empty` and reads the
    /// acoustic-loopback explainer banner in SessionDetailView. After
    /// that, the banner stops appearing on subsequent empty-audio
    /// sessions — the user has been told once, no need to repeat the
    /// same paragraph every time they open one. Pre-1.0.6.12 the
    /// banner showed unconditionally on every affected session, which
    /// for a tester whose mac happens to trip the macOS 26 SCStream
    /// regression meant a wall of identical orange explainers across
    /// 50+ retroactive sessions after the 1.0.6.11 update.
    var hasSeenAcousticLoopbackExplainer: Bool {
        didSet {
            defaults.set(hasSeenAcousticLoopbackExplainer,
                         forKey: Self.k_hasSeenAcousticLoopbackExplainer)
        }
    }

    /// When ON, finishing a session (Stop & save → summary done)
    /// automatically pushes it to Notion using the credentials in
    /// the same tab. Default OFF — opt-in because the first time
    /// a user records they probably don't want a half-tested
    /// integration writing into their workspace. Honoured only if
    /// `hasNotionCredentials` is true at the moment the session
    /// completes — otherwise silently skipped.
    var autoSendNotion: Bool {
        didSet { defaults.set(autoSendNotion, forKey: Self.k_autoSendNotion) }
    }

    /// Timestamp of the last successful Notion Test connection
    /// probe. Drives the UI gate that lets the user flip
    /// `autoSendNotion` ON — without a passing test we can't be sure
    /// the credentials work, the parent type is right, and the
    /// title column is named "Name" (for databases). Auto-send
    /// without a confirmed test would silently fail every session.
    /// `nil` (or .distantPast) means never tested.
    var lastNotionTestPassedAt: Date? {
        didSet {
            if let date = lastNotionTestPassedAt {
                defaults.set(date.timeIntervalSince1970, forKey: Self.k_lastNotionTestPassedAt)
            } else {
                defaults.removeObject(forKey: Self.k_lastNotionTestPassedAt)
            }
        }
    }

    /// Identifier for the user's preferred "default" destination —
    /// the one that fires when they click `Send to` in History
    /// without expanding the dropdown.
    ///
    /// Wire format:
    ///   • `""` — no default; Send-to always opens the menu
    ///     (legacy behaviour for users who didn't set one).
    ///   • `"notion"` — first-party REST connector.
    ///   • Any other string — the `MCPIntegration.id.uuidString`
    ///     of a configured MCP integration.
    ///
    /// Resolution is lazy at click time; if the saved ID points
    /// at a deleted / disabled integration we silently fall back
    /// to opening the menu.
    var defaultDestinationID: String {
        didSet { defaults.set(defaultDestinationID, forKey: Self.k_defaultDestinationID) }
    }

    /// Whether the Notion parent ID points at a page (the default,
    /// historical behaviour — Daisy creates the session as a child
    /// page under it) or at a database (Daisy creates the session
    /// as a database row, with title property "Name"). Stored as a
    /// string for forward compatibility with possible future kinds.
    var notionParentKind: String {
        didSet {
            defaults.set(notionParentKind, forKey: Self.k_notionParentKind)
            if notionParentKind != oldValue { lastNotionTestPassedAt = nil }
        }
    }

    /// Folder slugs that Notion auto-send applies to. Empty = all
    /// folders (the simple case). Non-empty restricts auto-send to
    /// just those folders — useful when you record Notes-style
    /// sessions you don't want pushed to a Notion team page.
    /// Manual Send-to from the kebab ignores this filter.
    var autoSendNotionFolders: Set<String> {
        didSet {
            if let data = try? JSONEncoder().encode(autoSendNotionFolders) {
                defaults.set(data, forKey: Self.k_autoSendNotionFolders)
            }
        }
    }

    /// When ON, Daisy auto-starts at the moment a calendar event with
    /// a detected meeting URL begins. Covers browser-based meetings
    /// (Google Meet in Chrome) that the NSWorkspace-based detector
    /// can't see. Requires calendar permission.
    var autoStartFromCalendar: Bool {
        didSet { defaults.set(autoStartFromCalendar, forKey: Self.k_autoStartFromCalendar) }
    }

    /// User has approved calendar reading. We persist a hint so the
    /// UI can show "permission granted" without re-querying TCC.
    /// EventKit itself is the source of truth.
    var calendarAccessGranted: Bool {
        didSet { defaults.set(calendarAccessGranted, forKey: Self.k_calendarAccessGranted) }
    }

    /// Whether the floating Daisy widget (the petal mark) appears on
    /// top of other windows during recording / paused / summarizing.
    /// ON by default — the widget is the always-visible affordance
    /// for pause / resume / stop without having to find the menu bar
    /// or main window. Users who don't want it can flip it off in
    /// Settings → Capture.
    var floatingWidgetEnabled: Bool {
        didSet { defaults.set(floatingWidgetEnabled, forKey: Self.k_floatingWidgetEnabled) }
    }

    /// When ON and the current session is bound to a calendar event,
    /// Daisy schedules an auto-stop at `meeting.endDate + grace`.
    /// A cancellable warning toast lets the user keep the session
    /// going past the calendar end if the conversation runs over.
    var autoStopFromCalendar: Bool {
        didSet { defaults.set(autoStopFromCalendar, forKey: Self.k_autoStopFromCalendar) }
    }

    /// Auto-stop grace period, in seconds. Two roles, one number:
    ///
    ///   1. **Earliest-stop offset** — the silence-gated auto-stop
    ///      (`RecordingSession.evaluateAutoStop`) won't even consider
    ///      stopping until `meeting.endDate + autoStopGraceSec`, and
    ///      then only after a further quiet stretch. So this is the
    ///      "wrap up, say goodbye, hop off" tail past a calendar event.
    ///   2. **Rejoin / merge window** (Talat's "grace period") — if you
    ///      leave a call and rejoin within this window the conversation
    ///      keeps flowing, so the silence gate never trips and the two
    ///      back-to-back stretches are captured as ONE recording rather
    ///      than two. Because the gate is silence-driven (not a fixed
    ///      timer), a longer grace simply widens the rejoin tolerance;
    ///      it does not, by itself, force a stop.
    ///
    /// Default 300 = 5 min. Talat exposes values as low as 1s, but for
    /// Daisy that's unsafe: with a 1s grace a 2-second pause to switch
    /// speakers could clip the tail of a live meeting, and the #48
    /// premature-stop class of bug lives exactly here. 5 min is the
    /// conservative default that covers a normal hop-off without risking
    /// a mid-meeting cut; the picker still offers shorter values for
    /// users who want them.
    var autoStopGraceSec: Int {
        didSet { defaults.set(autoStopGraceSec, forKey: Self.k_autoStopGraceSec) }
    }

    // ─── MCP server (Phase 6a) ────────────────────────────────────────
    //
    // Daisy can expose its sessions to external AI clients (Claude
    // Desktop, Claude Code, Cowork, Cursor, …) via the Model Context
    // Protocol. Transport: HTTP + SSE on a loopback port — nothing
    // ever leaves the Mac. Opt-in.

    /// Whether the local MCP server is running.
    var mcpServerEnabled: Bool {
        didSet { defaults.set(mcpServerEnabled, forKey: Self.k_mcpServerEnabled) }
    }

    /// Loopback TCP port the MCP server binds to. Default 54321;
    /// user can change it if there's a conflict.
    var mcpServerPort: Int {
        didSet { defaults.set(mcpServerPort, forKey: Self.k_mcpServerPort) }
    }

    // ─── MCP summarizer (Phase 6b) ────────────────────────────────────
    //
    // Daisy can ALSO be an MCP client — used by the .mcp provider
    // to call a user-configured local LLM wrapper. Independent from
    // the server above; same protocol, opposite direction.

    /// Base URL of the MCP server that wraps the local LLM.
    /// Empty string means unconfigured.
    var mcpSummarizerURL: String {
        didSet { defaults.set(mcpSummarizerURL, forKey: Self.k_mcpSummarizerURL) }
    }

    /// Tool name to call on that server.
    var mcpSummarizerToolName: String {
        didSet { defaults.set(mcpSummarizerToolName, forKey: Self.k_mcpSummarizerToolName) }
    }

    /// JSON template for the tool's `arguments` field. Supports
    /// `{{system}}` / `{{transcript}}` / `{{title}}` placeholders
    /// which Daisy substitutes before sending.
    var mcpSummarizerArgumentsTemplate: String {
        didSet { defaults.set(mcpSummarizerArgumentsTemplate, forKey: Self.k_mcpSummarizerArgsTemplate) }
    }

    // Secret prefs — mirrored in Keychain, exposed read/write here for the
    // settings view. Read-through on access, write-through on assignment.
    //
    // Keychain failures are rare but real (locked keychain, sandbox
    // misconfig). Swallowing them silently meant a user could paste a
    // key, see no error, and discover later that it never persisted.
    // Now they get a toast.
    var notionToken: String {
        didSet {
            Self.persist(notionToken, account: SecretKey.notionToken, label: "Notion token")
            // New token → old test result no longer reflects this
            // configuration. Force a re-test before auto-send can
            // be re-enabled.
            if notionToken != oldValue { lastNotionTestPassedAt = nil }
        }
    }
    var notionParentID: String {
        didSet {
            Self.persist(notionParentID, account: SecretKey.notionParentID, label: "Notion parent ID")
            if notionParentID != oldValue { lastNotionTestPassedAt = nil }
        }
    }
    var anthropicAPIKey: String {
        didSet {
            Self.persist(anthropicAPIKey, account: SecretKey.anthropicAPIKey, label: "Anthropic API key")
            Task { @MainActor in await Summarizer.shared.refreshAvailability() }
        }
    }
    var openaiAPIKey: String {
        didSet {
            Self.persist(openaiAPIKey, account: SecretKey.openaiAPIKey, label: "OpenAI API key")
            Task { @MainActor in await Summarizer.shared.refreshAvailability() }
        }
    }

    @MainActor
    private static func persist(_ value: String, account: String, label: String) {
        do {
            try KeychainStore.set(value, account: account)
        } catch {
            Self.log.error("Keychain write failed for \(label, privacy: .public): \(error.localizedDescription, privacy: .public)")
            ToastCenter.shared.show("Couldn’t save \(label) — try again.", style: .error)
        }
    }

    /// Project `autoStartPolicy` onto the three substrate flags the
    /// detection plumbing actually reads. Kept as a single method so
    /// the init-time derivation and the runtime `didSet` can't drift.
    /// Assigning the bools fires THEIR `didSet` (persistence) and, at
    /// runtime, the MainView `.onChange(of:)` re-wiring — exactly the
    /// path the old two-toggle UI used, so no extra wiring is needed.
    private func applyAutoStartPolicyToSubstrate() {
        switch autoStartPolicy {
        case .always:
            if autoStartOnMeeting != true { autoStartOnMeeting = true }
            if autoStartFromCalendar != true { autoStartFromCalendar = true }
            if autoStartPromptMode != false { autoStartPromptMode = false }
        case .selective:
            // Calendar-synced meetings only — app-launch detector off.
            if autoStartOnMeeting != false { autoStartOnMeeting = false }
            if autoStartFromCalendar != true { autoStartFromCalendar = true }
            if autoStartPromptMode != false { autoStartPromptMode = false }
        case .prompt:
            // Both detectors armed, but they ask before recording.
            if autoStartOnMeeting != true { autoStartOnMeeting = true }
            if autoStartFromCalendar != true { autoStartFromCalendar = true }
            if autoStartPromptMode != true { autoStartPromptMode = true }
        case .manual:
            if autoStartOnMeeting != false { autoStartOnMeeting = false }
            if autoStartFromCalendar != false { autoStartFromCalendar = false }
            if autoStartPromptMode != false { autoStartPromptMode = false }
        }
    }

    private static let log = Logger(subsystem: "app.essazanov.Daisy", category: "AppSettings")

    private let defaults = UserDefaults.standard

    init() {
        // Default ON: a meeting capture app capturing only the mic
        // misses half the conversation. macOS permission prompt
        // fires lazily on first record, so the cost of `true` here
        // is zero until the user actually starts recording.
        self.captureSystemAudio = defaults.object(forKey: Self.k_captureSystemAudio) as? Bool ?? true
        self.selectedMicDeviceUID = defaults.string(forKey: Self.k_selectedMicDeviceUID) ?? ""
        self.screenshotsEnabled = defaults.bool(forKey: Self.k_screenshotsEnabled)
        let interval = defaults.integer(forKey: Self.k_screenshotInterval)
        self.screenshotIntervalSec = interval > 0 ? interval : 60
        // Default OFF — when the user hasn't picked a summarizer
        // provider yet (no Anthropic / OpenAI key, no MCP server,
        // Apple Intelligence not detected) auto-summarize would
        // either silently no-op or — worse — fire a request against
        // a half-configured cloud account. Off-by-default keeps the
        // first-time experience honest; the user flips it on once
        // they've set up a provider.
        self.autoSummarize = defaults.object(forKey: Self.k_autoSummarize) as? Bool ?? false
        self.summaryLanguage = defaults.string(forKey: Self.k_summaryLanguage) ?? SummaryLanguage.auto.id
        self.defaultTranscriptionLocale = defaults.string(forKey: Self.k_defaultTranscriptionLocale) ?? "auto"
        // Per-mode overrides — empty string means "inherit from
        // defaultTranscriptionLocale". Users opt into language-
        // pinned dictation/voice-note explicitly.
        self.voiceNoteLocale = defaults.string(forKey: Self.k_voiceNoteLocale) ?? ""
        self.dictationLocale = defaults.string(forKey: Self.k_dictationLocale) ?? ""
        // Defaults to false (Whisper) when the key is absent.
        self.dictationUseParakeet = defaults.bool(forKey: Self.k_dictationUseParakeet)
        // Defaults to false (Whisper live preview) when the key is absent.
        self.dictationUseNemotronLive = defaults.bool(forKey: Self.k_dictationUseNemotronLive)
        // Decode HotkeyChoice from UserDefaults JSON. Fall back to
        // ⌃⌥⌘R default if missing/corrupt. (Old enum-based string
        // values from pre-v1.1 installs are now invalid and will
        // silently fall back.)
        if let data = defaults.data(forKey: Self.k_recordHotkey),
           let decoded = try? JSONDecoder().decode(HotkeyChoice.self, from: data) {
            self.recordHotkey = decoded
        } else {
            self.recordHotkey = .ctrlOptCmdR
        }
        // Voice-note + dictation hotkeys default to `.none` so users
        // who don't know they exist don't get unexpected behaviour.
        // Users opt in by picking a binding in Settings → Connections.
        if let data = defaults.data(forKey: Self.k_voiceNoteHotkey),
           let decoded = try? JSONDecoder().decode(HotkeyChoice.self, from: data) {
            self.voiceNoteHotkey = decoded
        } else {
            self.voiceNoteHotkey = .none
        }
        if let data = defaults.data(forKey: Self.k_dictationHotkey),
           let decoded = try? JSONDecoder().decode(HotkeyChoice.self, from: data) {
            self.dictationHotkey = decoded
        } else {
            self.dictationHotkey = .none
        }
        // Default OFF — auto-starting a recording the moment Zoom
        // / Teams / Telegram opens is surprising on first install
        // ("Daisy started recording a personal call I made
        // immediately after installing it"). It's a powerful
        // feature but needs opt-in. Users who want the headline
        // "Daisy captures every meeting" workflow flip it on in
        // Settings → Capture → Activation.
        // Capture into a local too: the auto-start POLICY derivation
        // below needs this value, but it runs before `self` is fully
        // initialized (Swift phase 1), where reading `self.autoStart…`
        // is illegal. Derive from the local instead.
        let loadedAutoStartOnMeeting = defaults.object(forKey: Self.k_autoStartOnMeeting) as? Bool ?? false
        self.autoStartOnMeeting = loadedAutoStartOnMeeting
        self.showSessionAfterStop = defaults.object(forKey: Self.k_showSessionAfterStop) as? Bool ?? false
        // Default ON — the prompt is the only safeguard against a
        // session left running for hours by accident. Users who
        // find it noisy can flip it off here.
        self.silencePromptsEnabled = defaults.object(forKey: Self.k_silencePromptsEnabled) as? Bool ?? true
        self.notifyOnAutoStart = defaults.object(forKey: Self.k_notifyOnAutoStart) as? Bool ?? true
        self.notifyOnAutoStop = defaults.object(forKey: Self.k_notifyOnAutoStop) as? Bool ?? true
        self.diarizeMicrophone = defaults.object(forKey: Self.k_diarizeMicrophone) as? Bool ?? false
        // Default ON. `defaults.object(forKey:) as? Bool ?? true`
        // pattern so fresh installs get live transcription on (the
        // historical behaviour) but the user's explicit OFF survives
        // across launches.
        // Live transcription tier (Full/Lite/Off). Migrates the pre-tier
        // binary toggle: a saved tier wins; else the old on/off bool maps
        // on→Lite (the new lighter default) / off→Off; else fresh install
        // defaults to Lite. The final pass on Stop is full quality at any
        // tier, so Lite only affects the throwaway live preview.
        if let raw = defaults.string(forKey: Self.k_liveTranscriptionTier),
           let tier = LiveTranscriptionTier(rawValue: raw) {
            self.liveTranscriptionTier = tier
        } else if let oldBool = defaults.object(forKey: Self.k_liveTranscriptionEnabled) as? Bool {
            self.liveTranscriptionTier = oldBool ? .lite : .off
        } else {
            self.liveTranscriptionTier = .lite
        }
        // 2026-05-25 — three diarization-quality settings added in
        // 1.0.7. All default ON so existing users get the new behavior
        // automatically (the changes are quality improvements, not
        // semantic shifts — diarizeRemoteSpeakers default matches the
        // prior implicit behavior; the other two are post-processing
        // passes that only run when the conditions trigger).
        self.diarizeRemoteSpeakers = defaults.object(forKey: Self.k_diarizeRemoteSpeakers) as? Bool ?? true
        self.diarizeUseAttendeeCountHint = defaults.object(forKey: Self.k_diarizeUseAttendeeCountHint) as? Bool ?? false
        self.suppressAcousticEcho = defaults.object(forKey: Self.k_suppressAcousticEcho) as? Bool ?? true
        self.globalReclusterAfterStop = defaults.object(forKey: Self.k_globalReclusterAfterStop) as? Bool ?? true
        self.userDisplayName = (defaults.string(forKey: Self.k_userDisplayName) ?? "")
        // Speaker match mode — default `.automatic` so existing users
        // (no stored value) keep the silent auto-label behaviour Daisy
        // has always had. Only an explicit user choice moves it off
        // Automatic. See `speakerMatchMode` doc for the three modes.
        if let rawMode = defaults.string(forKey: Self.k_speakerMatchMode),
           let mode = SpeakerMatchMode(rawValue: rawMode) {
            self.speakerMatchMode = mode
        } else {
            self.speakerMatchMode = .automatic
        }
        // 24-hour retention is the new default for fresh installs
        // (1.0.6.9+). Raw audio dominates Daisy's disk footprint
        // (~50-150 MB / hour) and an unbounded default bit a
        // tester whose Mac was already close to full.
        //
        // CRITICAL: existing users who never opened Settings →
        // Storage and never changed the retention picker must NOT
        // suddenly lose yesterday's audio because we flipped the
        // default — they didn't opt in. So we gate the new default
        // on `hasShownFirstRun`: false means a fresh install (no
        // first-run sheet shown yet), true means an existing
        // install that's been launched before. Anyone with an
        // explicit value in UserDefaults keeps it regardless;
        // `defaults.object(...) as? Int` returns nil only for keys
        // that were never written.
        // 2026-05-25 — fresh-install default changed from `1` (24h
        // timer sweep) to `audioRetentionDeleteAfterTranscription`
        // (-1; per-session purge after the post-stop pipeline). New
        // installs get the strongest privacy posture without losing
        // the option to keep audio; existing users who never opened
        // Settings → Storage still default to `0` (keep forever) to
        // preserve backwards-compat — they didn't opt in to any
        // purge behaviour and the upgrade shouldn't surprise-delete
        // yesterday's recordings. Anyone with an explicit value in
        // UserDefaults keeps it (storedRetention non-nil path).
        let storedRetention = defaults.object(forKey: Self.k_audioRetentionDays) as? Int
        let isFreshInstall = !defaults.bool(forKey: Self.k_hasShownFirstRun)
        self.audioRetentionDays = storedRetention
            ?? (isFreshInstall ? Self.audioRetentionDeleteAfterTranscription : 0)
        self.recordingSoundsEnabled = defaults.object(forKey: Self.k_recordingSoundsEnabled) as? Bool ?? true
        self.menuBarShowsNextMeeting = defaults.object(forKey: Self.k_menuBarShowsNextMeeting) as? Bool ?? false
        self.hasShownFirstRun = defaults.bool(forKey: Self.k_hasShownFirstRun)
        self.hasSeenAcousticLoopbackExplainer =
            defaults.bool(forKey: Self.k_hasSeenAcousticLoopbackExplainer)
        self.autoSendNotion = defaults.object(forKey: Self.k_autoSendNotion) as? Bool ?? false
        let lastTs = defaults.double(forKey: Self.k_lastNotionTestPassedAt)
        self.lastNotionTestPassedAt = lastTs > 0 ? Date(timeIntervalSince1970: lastTs) : nil
        self.defaultDestinationID = defaults.string(forKey: Self.k_defaultDestinationID) ?? ""
        self.notionParentKind = defaults.string(forKey: Self.k_notionParentKind) ?? "page"
        if let data = defaults.data(forKey: Self.k_autoSendNotionFolders),
           let decoded = try? JSONDecoder().decode(Set<String>.self, from: data) {
            self.autoSendNotionFolders = decoded
        } else {
            self.autoSendNotionFolders = []
        }
        // Local copy for the policy derivation below (same phase-1
        // reason as `loadedAutoStartOnMeeting`).
        let loadedAutoStartFromCalendar = defaults.object(forKey: Self.k_autoStartFromCalendar) as? Bool ?? false
        self.autoStartFromCalendar = loadedAutoStartFromCalendar
        self.calendarAccessGranted = defaults.bool(forKey: Self.k_calendarAccessGranted)
        // Auto-start policy (1.0.7.9). The two legacy bools above are
        // now derived outputs of this. Migration so existing users see
        // ZERO behavioural change:
        //   • A previously-saved policy wins (user already moved to the
        //     new control).
        //   • Otherwise derive from the legacy bools that were just
        //     loaded — whatever the old two-toggle UI left us:
        //        app-launch ON, calendar ON  → .always
        //        app-launch OFF, calendar ON → .selective
        //        app-launch ON, calendar OFF → .always (app-launch was
        //          the headline "capture every meeting" path; treat the
        //          presence of ANY auto-start as Always so we never
        //          silently DOWNGRADE a user who had a detector armed)
        //        both OFF                     → .manual (the fresh-install
        //          default, since both bools default OFF)
        // The fresh-install default is therefore .manual — identical to
        // today's clean install (both toggles off). `autoStartPromptMode`
        // had no equivalent before, so it can only come from an explicit
        // .prompt policy; default false.
        let hadStoredPolicy: Bool
        if let rawPolicy = defaults.string(forKey: Self.k_autoStartPolicy),
           let policy = AutoStartPolicy(rawValue: rawPolicy) {
            self.autoStartPolicy = policy
            hadStoredPolicy = true
        } else if loadedAutoStartOnMeeting || loadedAutoStartFromCalendar {
            // Legacy users with at least one detector armed. App-launch
            // alone (calendar off) still maps to Always rather than
            // inventing an "app-only" mode — Selective is explicitly
            // calendar-driven, so it would be the wrong label.
            // NB: read the just-loaded LOCALS, not self.* — this runs in
            // init phase 1 (not all stored properties assigned yet), so
            // reading instance properties through self is rejected.
            self.autoStartPolicy = (!loadedAutoStartOnMeeting && loadedAutoStartFromCalendar)
                ? .selective
                : .always
            hadStoredPolicy = false
        } else {
            self.autoStartPolicy = .manual
            hadStoredPolicy = false
        }
        self.didLoadStoredAutoStartPolicy = hadStoredPolicy
        self.autoStartPromptMode = defaults.object(forKey: Self.k_autoStartPromptMode) as? Bool ?? false
        // Default ON: `object(forKey:)` returns nil for unset keys, so
        // `as? Bool ?? true` picks up explicit user choices (true OR
        // false) and falls through to true only on a clean install.
        self.floatingWidgetEnabled = defaults.object(forKey: Self.k_floatingWidgetEnabled) as? Bool ?? true
        // Default ON. `defaults.bool(forKey:)` returns false for unset
        // keys, which meant a clean-install user never had calendar
        // auto-stop armed — combined with the "back-to-back meetings
        // bleed into one session" bug (fixed in RecordingSession.
        // startFromMeeting), that produced the failure mode where
        // M1 + M2 collapsed into a single 75-min recording with one
        // title. `object(forKey:) as? Bool ?? true` preserves an
        // explicit user-off choice while defaulting fresh installs
        // to the safer behaviour.
        self.autoStopFromCalendar = defaults.object(forKey: Self.k_autoStopFromCalendar) as? Bool ?? true
        let storedGrace = defaults.integer(forKey: Self.k_autoStopGraceSec)
        self.autoStopGraceSec = storedGrace > 0 ? storedGrace : 300
        self.mcpServerEnabled = defaults.bool(forKey: Self.k_mcpServerEnabled)
        let storedPort = defaults.integer(forKey: Self.k_mcpServerPort)
        self.mcpServerPort = storedPort > 0 ? storedPort : 54321
        self.mcpSummarizerURL = defaults.string(forKey: Self.k_mcpSummarizerURL)
            ?? MCPSummarizer.defaultBaseURLString
        self.mcpSummarizerToolName = defaults.string(forKey: Self.k_mcpSummarizerToolName)
            ?? MCPSummarizer.defaultToolName
        self.mcpSummarizerArgumentsTemplate = defaults.string(forKey: Self.k_mcpSummarizerArgsTemplate)
            ?? MCPSummarizer.defaultArgumentsTemplate
        self.notionToken = KeychainStore.get(account: SecretKey.notionToken) ?? ""
        self.notionParentID = KeychainStore.get(account: SecretKey.notionParentID) ?? ""
        self.anthropicAPIKey = KeychainStore.get(account: SecretKey.anthropicAPIKey) ?? ""
        self.openaiAPIKey = KeychainStore.get(account: SecretKey.openaiAPIKey) ?? ""

        // Reconcile substrate to the policy ONCE at launch — but ONLY
        // when the policy came from an explicit stored value. `didSet`
        // doesn't fire during init, so if a previously-saved policy
        // disagrees with the stored bools (user round-tripped through an
        // older build that flipped a bool directly), the policy is
        // authoritative and we re-derive the bools from it. On the LEGACY
        // path (no stored policy) we skip this: the policy was derived
        // FROM the bools, so they already agree, and reconciling could
        // change behaviour (an app-launch-only user → .always would
        // otherwise gain calendar auto-start). Safe to run before wiring:
        // ServiceWiring.applyAll runs later in DaisyApp.init off the
        // now-consistent values.
        if didLoadStoredAutoStartPolicy {
            applyAutoStartPolicyToSubstrate()
        }
    }

    var hasNotionCredentials: Bool {
        !notionToken.isEmpty && !notionParentID.isEmpty
    }

    /// Static convenience for places (Toolbar actions in
    /// SessionDetailView) that don't have AppSettings injected and
    /// just need a yes/no on Notion configuration. Reads Keychain
    /// directly to avoid singleton wiring.
    nonisolated static var notionConfigured: Bool {
        let token = KeychainStore.get(account: SecretKey.notionToken) ?? ""
        let parent = KeychainStore.get(account: SecretKey.notionParentID) ?? ""
        return !token.isEmpty && !parent.isEmpty
    }

    /// Read-only static accessor for the summary-language preference,
    /// readable from `nonisolated` contexts (e.g. SessionDetailView's
    /// `reSummarize()` which needs to feed the canonical locale
    /// resolver in `RecordingSession.resolveSummaryLocaleHint`
    /// without holding a live `AppSettings` instance). Returns "auto"
    /// if never explicitly set, matching the init() default.
    nonisolated static var currentSummaryLanguage: String {
        UserDefaults.standard.string(forKey: k_summaryLanguage) ?? "auto"
    }

    private static let k_captureSystemAudio = "daisy.captureSystemAudio"
    private static let k_selectedMicDeviceUID = "daisy.selectedMicDeviceUID"
    private static let k_screenshotsEnabled = "daisy.screenshotsEnabled"
    private static let k_screenshotInterval = "daisy.screenshotIntervalSec"
    private static let k_autoSummarize = "daisy.autoSummarize"
    private static let k_showSessionAfterStop = "daisy.showSessionAfterStop"
    /// `nonisolated` because `currentSummaryLanguage` (above) reads
    /// this key from a nonisolated context (SessionDetailView's
    /// reSummarize() path), and Swift 6's default MainActor isolation
    /// on AppSettings would otherwise propagate to the static and
    /// emit a "main-actor isolated static can't be referenced from
    /// nonisolated context" error. The string is a plain `let` with
    /// no shared mutation — safe to read from any actor.
    nonisolated private static let k_summaryLanguage = "daisy.summaryLanguage"
    private static let k_defaultTranscriptionLocale = "daisy.defaultTranscriptionLocale"
    private static let k_voiceNoteLocale = "daisy.voiceNoteLocale"
    private static let k_dictationLocale = "daisy.dictationLocale"
    private static let k_dictationUseParakeet = "daisy.dictationUseParakeet"
    private static let k_dictationUseNemotronLive = "daisy.dictationUseNemotronLive"
    private static let k_recordHotkey = "daisy.recordHotkey"
    private static let k_voiceNoteHotkey = "daisy.voiceNoteHotkey"
    private static let k_dictationHotkey = "daisy.dictationHotkey"
    private static let k_autoStartOnMeeting = "daisy.autoStartOnMeeting"
    private static let k_autoStartPolicy = "daisy.autoStartPolicy"
    private static let k_autoStartPromptMode = "daisy.autoStartPromptMode"
    private static let k_silencePromptsEnabled = "daisy.silencePromptsEnabled"
    private static let k_notifyOnAutoStart = "daisy.notifyOnAutoStart"
    private static let k_notifyOnAutoStop = "daisy.notifyOnAutoStop"
    private static let k_diarizeMicrophone = "daisy.diarizeMicrophone"
    private static let k_liveTranscriptionEnabled = "daisy.liveTranscriptionEnabled"
    private static let k_liveTranscriptionTier = "daisy.liveTranscriptionTier"
    private static let k_diarizeRemoteSpeakers = "daisy.diarizeRemoteSpeakers"
    private static let k_diarizeUseAttendeeCountHint = "daisy.diarizeUseAttendeeCountHint"
    private static let k_suppressAcousticEcho = "daisy.suppressAcousticEcho"
    private static let k_globalReclusterAfterStop = "daisy.globalReclusterAfterStop"
    private static let k_userDisplayName = "daisy.userDisplayName"
    private static let k_speakerMatchMode = "daisy.speakerMatchMode"
    private static let k_audioRetentionDays = "daisy.audioRetentionDays"
    private static let k_recordingSoundsEnabled = "daisy.recordingSoundsEnabled"
    private static let k_menuBarShowsNextMeeting = "daisy.menuBarShowsNextMeeting"
    private static let k_hasShownFirstRun = "daisy.hasShownFirstRun"
    private static let k_hasSeenAcousticLoopbackExplainer =
        "daisy.hasSeenAcousticLoopbackExplainer"
    private static let k_autoSendNotion = "daisy.autoSendNotion"
    private static let k_lastNotionTestPassedAt = "daisy.lastNotionTestPassedAt"
    private static let k_defaultDestinationID = "daisy.defaultDestinationID"
    private static let k_notionParentKind = "daisy.notionParentKind"
    private static let k_autoSendNotionFolders = "daisy.autoSendNotionFolders"
    private static let k_autoStartFromCalendar = "daisy.autoStartFromCalendar"
    private static let k_calendarAccessGranted = "daisy.calendarAccessGranted"
    private static let k_floatingWidgetEnabled = "daisy.floatingWidgetEnabled"
    private static let k_autoStopFromCalendar = "daisy.autoStopFromCalendar"
    private static let k_autoStopGraceSec = "daisy.autoStopGraceSec"
    private static let k_mcpServerEnabled = "daisy.mcpServerEnabled"
    private static let k_mcpServerPort = "daisy.mcpServerPort"
    private static let k_mcpSummarizerURL = "daisy.mcpSummarizer.url"
    private static let k_mcpSummarizerToolName = "daisy.mcpSummarizer.toolName"
    private static let k_mcpSummarizerArgsTemplate = "daisy.mcpSummarizer.argsTemplate"
}

// MARK: - AutoStartPolicy

/// How aggressively Daisy auto-records detected calls. Modelled on
/// Talat's Settings → Recordings auto-start control. `rawValue` is the
/// stable string persisted in `AppSettings.autoStartPolicy`.
///
/// Detection itself (NSWorkspace app-launch + calendar-event) is
/// unchanged — the policy only decides what to DO when a call is
/// detected. See `AppSettings.autoStartPolicy` for the full mapping
/// onto the substrate flags.
enum AutoStartPolicy: String, CaseIterable, Identifiable, Sendable {
    /// Auto-record every detected call (app-launch + calendar), starting
    /// immediately and silently.
    case always
    /// Auto-record only calendar-synced meetings (events with a
    /// Zoom/Meet/Teams/Webex link). App-launch detection is suppressed.
    case selective
    /// Detect the call but ASK first (Record / Ignore banner) before
    /// recording. Applies to both detectors.
    case prompt
    /// Never auto-start — only the Record button / hotkey.
    case manual

    nonisolated var id: String { rawValue }

    /// Short label for the auto-start selector (the pop-up menu in
    /// Settings → Auto-start). Plain-language names — what Daisy records,
    /// not the internal policy word.
    nonisolated var displayName: String {
        switch self {
        case .always:    return "All meetings"
        case .selective: return "Meetings with a link"
        case .prompt:    return "Ask me first"
        case .manual:    return "Off"
        }
    }
}

// MARK: - SpeakerMatchMode

/// How aggressively Daisy applies a recognized speaker (by voice
/// fingerprint and/or calendar-attendee email) to a new recording.
/// Modelled on Talat's Settings → Speakers match control. `rawValue`
/// is the stable string persisted in `AppSettings.speakerMatchMode`.
///
/// The recognition itself (cosine match in `SpeakerProfileStore` +
/// email intersection) is unchanged across modes — the mode only
/// decides what to DO with a hit: apply it, suggest it, or ignore it.
/// See `AppSettings.speakerMatchMode` for the per-mode behaviour.
enum SpeakerMatchMode: String, CaseIterable, Identifiable, Sendable {
    /// No cross-meeting auto-match. Speakers stay Remote A/B/C until
    /// named by hand. Voice fingerprints are still persisted on manual
    /// naming so re-enabling later works.
    case off
    /// Recognize, but surface as a confirmable suggestion rather than
    /// applying it. The user approves before names enter the transcript.
    case suggest
    /// Apply the match silently (pre-fills the transcript speaker map).
    /// Daisy's behaviour in every build before 1.0.7.10 — the default.
    case automatic

    nonisolated var id: String { rawValue }

    /// Label for the segmented control.
    nonisolated var displayName: String {
        switch self {
        case .off:       return "Off"
        case .suggest:   return "Suggest"
        case .automatic: return "Automatic"
        }
    }
}

// MARK: - SummaryLanguage

/// Languages the user can pin the AI summary to. Decoupled from
/// transcription locale — the transcript stays in its captured
/// language, only the summary text is shifted.
///
/// `id` is the 2-letter ISO code stored in `AppSettings.summaryLanguage`,
/// or the literal `"auto"` for "use the transcript's language".
/// Live-transcription cost tier, surfaced in Settings → Transcription.
/// `full` is the original behaviour (turbo model, 2 s cadence, full
/// decode); `lite` trims cadence + decode for a much lighter live
/// preview; `off` shows no live transcript and runs a single full pass
/// on Stop (the build-43 "deferred" path). The final transcript on Stop
/// is always full quality regardless of tier.
enum LiveTranscriptionTier: String, CaseIterable, Identifiable, Sendable {
    case full
    case lite
    case off

    nonisolated var id: String { rawValue }

    nonisolated var displayName: String {
        switch self {
        case .full: return "Full"
        case .lite: return "Lite"
        case .off:  return "Off"
        }
    }
}

/// `displayName` is what the picker shows. The order roughly mirrors
/// `Transcriber.availableLocales` so the two pickers feel related.
enum SummaryLanguage: String, CaseIterable, Identifiable, Sendable {
    case auto
    case en
    case ru
    case uk
    case pl
    case es
    case fr
    case de
    case it
    case pt
    case ja
    case ko
    case zh

    nonisolated var id: String { rawValue }

    nonisolated var displayName: String {
        switch self {
        case .auto: return "Auto · same as transcript"
        case .en:   return "English"
        case .ru:   return "Русский"
        case .uk:   return "Українська"
        case .pl:   return "Polski"
        case .es:   return "Español"
        case .fr:   return "Français"
        case .de:   return "Deutsch"
        case .it:   return "Italiano"
        case .pt:   return "Português"
        case .ja:   return "日本語"
        case .ko:   return "한국어"
        case .zh:   return "中文"
        }
    }
}
