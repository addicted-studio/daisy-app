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
    var screenshotsEnabled: Bool {
        didSet { defaults.set(screenshotsEnabled, forKey: Self.k_screenshotsEnabled) }
    }
    var screenshotIntervalSec: Int {
        didSet { defaults.set(screenshotIntervalSec, forKey: Self.k_screenshotInterval) }
    }
    var autoSummarize: Bool {
        didSet { defaults.set(autoSummarize, forKey: Self.k_autoSummarize) }
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
        self.captureSystemAudio = defaults.object(forKey: Self.k_captureSystemAudio) as? Bool ?? false
        self.screenshotsEnabled = defaults.bool(forKey: Self.k_screenshotsEnabled)
        let interval = defaults.integer(forKey: Self.k_screenshotInterval)
        self.screenshotIntervalSec = interval > 0 ? interval : 60
        self.autoSummarize = defaults.object(forKey: Self.k_autoSummarize) as? Bool ?? true
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
    private static let k_screenshotsEnabled = "daisy.screenshotsEnabled"
    private static let k_screenshotInterval = "daisy.screenshotIntervalSec"
    private static let k_autoSummarize = "daisy.autoSummarize"
    private static let k_recordHotkey = "daisy.recordHotkey"
    private static let k_autoStartOnMeeting = "daisy.autoStartOnMeeting"
    private static let k_autoStartFromCalendar = "daisy.autoStartFromCalendar"
    private static let k_calendarAccessGranted = "daisy.calendarAccessGranted"
}
