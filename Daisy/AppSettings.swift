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

    /// Global record-toggle hotkey. `.none` disables. Stored in
    /// UserDefaults as JSON (struct, not enum any more).
    var recordHotkey: HotkeyChoice {
        didSet {
            if let data = try? JSONEncoder().encode(recordHotkey) {
                defaults.set(data, forKey: Self.k_recordHotkey)
            }
        }
    }

    /// When ON, Daisy auto-starts a recording the moment one of the
    /// known meeting apps (Zoom / Teams / Telegram / etc.) launches.
    var autoStartOnMeeting: Bool {
        didSet { defaults.set(autoStartOnMeeting, forKey: Self.k_autoStartOnMeeting) }
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
        didSet { Self.persist(notionToken, account: SecretKey.notionToken, label: "Notion token") }
    }
    var notionParentID: String {
        didSet { Self.persist(notionParentID, account: SecretKey.notionParentID, label: "Notion parent ID") }
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
        self.autoSummarize = defaults.object(forKey: Self.k_autoSummarize) as? Bool ?? true
        self.summaryLanguage = defaults.string(forKey: Self.k_summaryLanguage) ?? SummaryLanguage.auto.id
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
        // Default ON: Daisy is a meeting capture app — the
        // "starts recording the moment Zoom/Teams/etc opens"
        // behaviour is the headline feature, not an opt-in.
        self.autoStartOnMeeting = defaults.object(forKey: Self.k_autoStartOnMeeting) as? Bool ?? true
        self.autoStartFromCalendar = defaults.object(forKey: Self.k_autoStartFromCalendar) as? Bool ?? false
        self.calendarAccessGranted = defaults.bool(forKey: Self.k_calendarAccessGranted)
        // Default ON: `object(forKey:)` returns nil for unset keys, so
        // `as? Bool ?? true` picks up explicit user choices (true OR
        // false) and falls through to true only on a clean install.
        self.floatingWidgetEnabled = defaults.object(forKey: Self.k_floatingWidgetEnabled) as? Bool ?? true
        self.autoStopFromCalendar = defaults.bool(forKey: Self.k_autoStopFromCalendar)
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

    private static let k_captureSystemAudio = "daisy.captureSystemAudio"
    private static let k_selectedMicDeviceUID = "daisy.selectedMicDeviceUID"
    private static let k_screenshotsEnabled = "daisy.screenshotsEnabled"
    private static let k_screenshotInterval = "daisy.screenshotIntervalSec"
    private static let k_autoSummarize = "daisy.autoSummarize"
    private static let k_summaryLanguage = "daisy.summaryLanguage"
    private static let k_recordHotkey = "daisy.recordHotkey"
    private static let k_autoStartOnMeeting = "daisy.autoStartOnMeeting"
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
