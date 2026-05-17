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

@Observable
@MainActor
final class AppSettings {
    // Non-secret prefs.
    var captureSystemAudio: Bool {
        didSet { defaults.set(captureSystemAudio, forKey: Self.k_captureSystemAudio) }
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

    /// Global record-toggle hotkey. `.none` disables.
    var recordHotkey: HotkeyChoice {
        didSet { defaults.set(recordHotkey.rawValue, forKey: Self.k_recordHotkey) }
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

    // Secret prefs — mirrored in Keychain, exposed read/write here for the
    // settings view. Read-through on access, write-through on assignment.
    var notionToken: String {
        didSet { try? KeychainStore.set(notionToken, account: SecretKey.notionToken) }
    }
    var notionParentID: String {
        didSet { try? KeychainStore.set(notionParentID, account: SecretKey.notionParentID) }
    }
    var anthropicAPIKey: String {
        didSet {
            try? KeychainStore.set(anthropicAPIKey, account: SecretKey.anthropicAPIKey)
            Task { @MainActor in await Summarizer.shared.refreshAvailability() }
        }
    }
    var openaiAPIKey: String {
        didSet {
            try? KeychainStore.set(openaiAPIKey, account: SecretKey.openaiAPIKey)
            Task { @MainActor in await Summarizer.shared.refreshAvailability() }
        }
    }

    private let defaults = UserDefaults.standard

    init() {
        self.captureSystemAudio = defaults.object(forKey: Self.k_captureSystemAudio) as? Bool ?? false
        self.screenshotsEnabled = defaults.bool(forKey: Self.k_screenshotsEnabled)
        let interval = defaults.integer(forKey: Self.k_screenshotInterval)
        self.screenshotIntervalSec = interval > 0 ? interval : 60
        self.autoSummarize = defaults.object(forKey: Self.k_autoSummarize) as? Bool ?? true
        self.recordHotkey = HotkeyChoice(
            rawValue: defaults.string(forKey: Self.k_recordHotkey) ?? ""
        ) ?? .ctrlOptCmdR
        self.autoStartOnMeeting = defaults.object(forKey: Self.k_autoStartOnMeeting) as? Bool ?? false
        self.autoStartFromCalendar = defaults.object(forKey: Self.k_autoStartFromCalendar) as? Bool ?? false
        self.calendarAccessGranted = defaults.bool(forKey: Self.k_calendarAccessGranted)
        self.notionToken = KeychainStore.get(account: SecretKey.notionToken) ?? ""
        self.notionParentID = KeychainStore.get(account: SecretKey.notionParentID) ?? ""
        self.anthropicAPIKey = KeychainStore.get(account: SecretKey.anthropicAPIKey) ?? ""
        self.openaiAPIKey = KeychainStore.get(account: SecretKey.openaiAPIKey) ?? ""
    }

    var hasNotionCredentials: Bool {
        !notionToken.isEmpty && !notionParentID.isEmpty
    }

    private static let k_captureSystemAudio = "hola.captureSystemAudio"
    private static let k_screenshotsEnabled = "hola.screenshotsEnabled"
    private static let k_screenshotInterval = "hola.screenshotIntervalSec"
    private static let k_autoSummarize = "hola.autoSummarize"
    private static let k_recordHotkey = "daisy.recordHotkey"
    private static let k_autoStartOnMeeting = "daisy.autoStartOnMeeting"
    private static let k_autoStartFromCalendar = "daisy.autoStartFromCalendar"
    private static let k_calendarAccessGranted = "daisy.calendarAccessGranted"
}
