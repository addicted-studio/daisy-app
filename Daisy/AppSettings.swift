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
    /// `AudioRecorder` resolves UID → live `AudioDeviceID` at every
    /// recording start, and silently falls back to system default if
    /// the saved device is gone (unplugged headset, removed USB
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
    var autoStartOnMeeting: Bool {
        didSet { defaults.set(autoStartOnMeeting, forKey: Self.k_autoStartOnMeeting) }
    }

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

    /// Days to keep raw audio (.caf) files for finished sessions.
    /// 0 == keep forever (default — preserves backwards-compat for
    /// existing users). Positive value triggers a background sweep
    /// at app launch that deletes microphone.caf / system_audio.caf
    /// older than the cutoff, but leaves transcript.md / summary.json
    /// / screenshots intact. Useful for users tight on disk —
    /// transcripts + summaries are tiny, audio dominates the footprint.
    var audioRetentionDays: Int {
        didSet { defaults.set(audioRetentionDays, forKey: Self.k_audioRetentionDays) }
    }

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

    /// Seconds past the calendar event's end before the auto-stop
    /// fires (default 300 = 5 min). Picked to cover the usual
    /// "wrap up, say goodbye, hop off" tail.
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
        self.autoStartOnMeeting = defaults.object(forKey: Self.k_autoStartOnMeeting) as? Bool ?? false
        self.showSessionAfterStop = defaults.object(forKey: Self.k_showSessionAfterStop) as? Bool ?? false
        // Default ON — the prompt is the only safeguard against a
        // session left running for hours by accident. Users who
        // find it noisy can flip it off here.
        self.silencePromptsEnabled = defaults.object(forKey: Self.k_silencePromptsEnabled) as? Bool ?? true
        self.notifyOnAutoStart = defaults.object(forKey: Self.k_notifyOnAutoStart) as? Bool ?? true
        self.notifyOnAutoStop = defaults.object(forKey: Self.k_notifyOnAutoStop) as? Bool ?? true
        self.diarizeMicrophone = defaults.object(forKey: Self.k_diarizeMicrophone) as? Bool ?? false
        self.userDisplayName = (defaults.string(forKey: Self.k_userDisplayName) ?? "")
        self.audioRetentionDays = defaults.object(forKey: Self.k_audioRetentionDays) as? Int ?? 0
        self.recordingSoundsEnabled = defaults.object(forKey: Self.k_recordingSoundsEnabled) as? Bool ?? true
        self.menuBarShowsNextMeeting = defaults.object(forKey: Self.k_menuBarShowsNextMeeting) as? Bool ?? false
        self.hasShownFirstRun = defaults.bool(forKey: Self.k_hasShownFirstRun)
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
        self.autoStartFromCalendar = defaults.object(forKey: Self.k_autoStartFromCalendar) as? Bool ?? false
        self.calendarAccessGranted = defaults.bool(forKey: Self.k_calendarAccessGranted)
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
    private static let k_recordHotkey = "daisy.recordHotkey"
    private static let k_voiceNoteHotkey = "daisy.voiceNoteHotkey"
    private static let k_dictationHotkey = "daisy.dictationHotkey"
    private static let k_autoStartOnMeeting = "daisy.autoStartOnMeeting"
    private static let k_silencePromptsEnabled = "daisy.silencePromptsEnabled"
    private static let k_notifyOnAutoStart = "daisy.notifyOnAutoStart"
    private static let k_notifyOnAutoStop = "daisy.notifyOnAutoStop"
    private static let k_diarizeMicrophone = "daisy.diarizeMicrophone"
    private static let k_userDisplayName = "daisy.userDisplayName"
    private static let k_audioRetentionDays = "daisy.audioRetentionDays"
    private static let k_recordingSoundsEnabled = "daisy.recordingSoundsEnabled"
    private static let k_menuBarShowsNextMeeting = "daisy.menuBarShowsNextMeeting"
    private static let k_hasShownFirstRun = "daisy.hasShownFirstRun"
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

// MARK: - SummaryLanguage

/// Languages the user can pin the AI summary to. Decoupled from
/// transcription locale — the transcript stays in its captured
/// language, only the summary text is shifted.
///
/// `id` is the 2-letter ISO code stored in `AppSettings.summaryLanguage`,
/// or the literal `"auto"` for "use the transcript's language".
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
