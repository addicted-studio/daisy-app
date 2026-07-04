//
//  MeetingLifecycleNotifications.swift
//  Daisy
//
//  macOS notification banners for two calendar-driven session
//  lifecycle events:
//
//   1. Auto-start  — when CalendarService.tick() begins recording
//                    automatically because a tracked meeting is
//                    starting. Banner shows the meeting title with
//                    one inline action: "Stop & save" (in case the
//                    user didn't actually want this meeting tracked).
//   2. Auto-stop   — when the post-event auto-stop fires after
//                    `meeting.endDate + graceSec`. Informational
//                    banner only — the recording is already saved.
//
//  Both gated on per-class toggles in `AppSettings.notifyOnAutoStart`
//  / `notifyOnAutoStop`. Authorization is requested lazily — the
//  user only sees the macOS auth prompt the first time we actually
//  try to surface a banner, not at app launch.
//
//  Architectural notes:
//   • Mirrors the same enum-static-funcs shape as
//     `SilencePromptNotification` for consistency. Re-using the
//     authorization request flow Apple already approved for that
//     surface — no extra TCC prompts.
//   • Action button taps come back via a Foundation
//     NotificationCenter broadcast, same channel SilencePrompt uses.
//     RecordingSession subscribes via the AppDelegate
//     notification-handler bridge.
//

import Foundation
@preconcurrency import UserNotifications

// MARK: - Auto-start

@MainActor
enum AutoStartNotification {

    static let requestID = "app.essazanov.Daisy.autoStart"
    static let categoryID = "app.essazanov.Daisy.autoStart.category"

    /// Action identifier — user tapped "Stop & save" on the banner.
    /// Broadcast over Foundation NotificationCenter; RecordingSession
    /// subscribes via DaisyAppDelegate and routes to `stop()`.
    static let actionStop = "AUTOSTART_STOP_AND_SAVE"

    static let stopRequested = Notification.Name("Daisy.autoStart.stopRequested")

    static func register() {
        let center = UNUserNotificationCenter.current()
        let stop = UNNotificationAction(
            identifier: actionStop,
            title: "Stop & save",
            options: [.foreground, .destructive]
        )
        let category = UNNotificationCategory(
            identifier: categoryID,
            actions: [stop],
            intentIdentifiers: [],
            options: []
        )
        // Merge with whatever's already registered (silence prompt,
        // auto-stop) rather than replacing — setNotificationCategories
        // is destructive otherwise.
        center.getNotificationCategories { existing in
            var merged = existing
            merged.insert(category)
            center.setNotificationCategories(merged)
        }
    }

    /// Surface the banner. `meetingTitle` shows in the body so the
    /// user can tell which meeting Daisy picked up. No-op when the
    /// user has disabled this class of notification.
    static func post(meetingTitle: String) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted {
                        Task { @MainActor in addRequest(title: meetingTitle) }
                    }
                }
            case .authorized, .provisional:
                Task { @MainActor in addRequest(title: meetingTitle) }
            case .denied, .ephemeral:
                break
            @unknown default:
                break
            }
        }
    }

    static func cancel() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [requestID])
        center.removeDeliveredNotifications(withIdentifiers: [requestID])
    }

    private static func addRequest(title: String) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Recording started")
        content.body = title.isEmpty
            ? String(localized: "Daisy is now recording your scheduled meeting.")
            : String(localized: "Daisy is now recording \"\(title)\".")
        content.sound = .default
        content.categoryIdentifier = categoryID
        let request = UNNotificationRequest(
            identifier: requestID,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}

// MARK: - Auto-start PROMPT (policy = .prompt)

/// "A call was detected — record it?" banner with Record / Ignore
/// actions, used when `AppSettings.autoStartPolicy == .prompt`. Unlike
/// `AutoStartNotification` (which fires AFTER an auto-start to offer a
/// bail-out), this fires BEFORE recording and gates it on the user's
/// choice. The pending trigger (which app / which meeting) is held on
/// `RecordingSession`; this banner just carries the user's yes/no back
/// over the Foundation bus, same pattern as `SilencePromptNotification`.
@MainActor
enum AutoStartPromptNotification {

    static let requestID = "app.essazanov.Daisy.autoStartPrompt"
    static let categoryID = "app.essazanov.Daisy.autoStartPrompt.category"

    /// User tapped "Record" — start the pending session.
    static let actionRecord = "AUTOSTART_PROMPT_RECORD"
    /// User tapped "Ignore" — drop the pending trigger.
    static let actionIgnore = "AUTOSTART_PROMPT_IGNORE"

    /// Broadcast on the main bus when the user picks Record.
    /// RecordingSession subscribes and starts the pending trigger.
    static let recordRequested = Notification.Name("Daisy.autoStartPrompt.recordRequested")
    /// Broadcast when the user picks Ignore (or dismisses the banner) —
    /// RecordingSession clears the pending trigger.
    static let ignoreRequested = Notification.Name("Daisy.autoStartPrompt.ignoreRequested")

    static func register() {
        let center = UNUserNotificationCenter.current()
        let record = UNNotificationAction(
            identifier: actionRecord,
            title: String(localized: "Record"),
            options: [.foreground]
        )
        let ignore = UNNotificationAction(
            identifier: actionIgnore,
            title: String(localized: "Ignore"),
            options: []
        )
        let category = UNNotificationCategory(
            identifier: categoryID,
            actions: [record, ignore],
            intentIdentifiers: [],
            options: []
        )
        center.getNotificationCategories { existing in
            var merged = existing
            merged.insert(category)
            center.setNotificationCategories(merged)
        }
    }

    /// Surface the ask. `subject` names what was detected ("Zoom",
    /// the meeting title) so the user can decide. No-op if notifications
    /// are denied — in that case `RecordingSession` falls back to a
    /// ToastCenter action prompt (so the ask is never silently lost).
    static func post(subject: String) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    Task { @MainActor in
                        if granted {
                            addRequest(subject: subject)
                        } else {
                            // Permission refused — surface the ask as a
                            // toast so Prompt mode still works.
                            AutoStartPromptNotification.postToastFallback(subject: subject)
                        }
                    }
                }
            case .authorized, .provisional:
                Task { @MainActor in addRequest(subject: subject) }
            case .denied, .ephemeral:
                Task { @MainActor in postToastFallback(subject: subject) }
            @unknown default:
                Task { @MainActor in postToastFallback(subject: subject) }
            }
        }
    }

    /// Toast-based equivalent of the banner for the notifications-denied
    /// case. "Record" runs the same broadcast the banner action would.
    static func postToastFallback(subject: String) {
        let label = subject.isEmpty ? String(localized: "a meeting") : subject
        ToastCenter.shared.showAction(
            String(localized: "Detected \(label) — record it?"),
            actionLabel: String(localized: "Record"),
            style: .info,
            duration: .seconds(20),
            perform: {
                NotificationCenter.default.post(
                    name: AutoStartPromptNotification.recordRequested, object: nil
                )
            }
        )
    }

    static func cancel() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [requestID])
        center.removeDeliveredNotifications(withIdentifiers: [requestID])
    }

    private static func addRequest(subject: String) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Record this meeting?")
        content.body = subject.isEmpty
            ? String(localized: "Daisy detected a meeting. Record it?")
            : String(localized: "Daisy detected \"\(subject)\". Record it?")
        content.sound = .default
        content.categoryIdentifier = categoryID
        let request = UNNotificationRequest(
            identifier: requestID,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}

// MARK: - Auto-stop

@MainActor
enum AutoStopNotification {

    static let requestID = "app.essazanov.Daisy.autoStop"
    // No action buttons — purely informational, default tap reveals
    // the session in History via the AppDelegate handler.
    static let categoryID = "app.essazanov.Daisy.autoStop.category"

    static func register() {
        let center = UNUserNotificationCenter.current()
        let category = UNNotificationCategory(
            identifier: categoryID,
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        center.getNotificationCategories { existing in
            var merged = existing
            merged.insert(category)
            center.setNotificationCategories(merged)
        }
    }

    static func post(meetingTitle: String) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted {
                        Task { @MainActor in addRequest(title: meetingTitle) }
                    }
                }
            case .authorized, .provisional:
                Task { @MainActor in addRequest(title: meetingTitle) }
            case .denied, .ephemeral:
                break
            @unknown default:
                break
            }
        }
    }

    static func cancel() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [requestID])
        center.removeDeliveredNotifications(withIdentifiers: [requestID])
    }

    private static func addRequest(title: String) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Meeting ended")
        content.body = title.isEmpty
            ? String(localized: "Recording saved.")
            : String(localized: "Recording for \"\(title)\" saved.")
        content.sound = .default
        content.categoryIdentifier = categoryID
        let request = UNNotificationRequest(
            identifier: requestID,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}

// MARK: - Auto-stop PROMPT (ask instead of stopping)

/// "Meeting seems over — stop & save?" banner with Stop & save /
/// 10 more minutes / 30 more minutes actions, used when
/// `AppSettings.autoStopPromptMode` is ON. Unlike `AutoStopNotification`
/// (a receipt AFTER the stop), this fires INSTEAD of the automatic stop
/// and gates it on the user's choice — the session keeps recording
/// until they answer (or the hard-max backstop in
/// `RecordingSession.evaluateAutoStop` force-stops an ignored ask).
/// Action taps come back over the Foundation bus, same pattern as
/// `AutoStartPromptNotification`. A body tap just opens the app; a
/// swipe-dismiss is silent (keep recording — the evaluator may ask
/// again later). No toast fallback here: `presentAutoStopPrompt`
/// always posts an in-app action toast alongside, so the ask is never
/// lost when notifications are denied.
@MainActor
enum AutoStopPromptNotification {

    static let requestID = "app.essazanov.Daisy.autoStopPrompt"
    static let categoryID = "daisy.autostop.prompt"

    /// User tapped "Stop & save" — stop the session now.
    static let actionStop = "AUTOSTOP_PROMPT_STOP"
    /// User tapped "10 more minutes" — snooze the evaluator.
    static let actionSnooze10 = "AUTOSTOP_PROMPT_SNOOZE_10"
    /// User tapped "30 more minutes" — snooze the evaluator.
    static let actionSnooze30 = "AUTOSTOP_PROMPT_SNOOZE_30"

    /// Broadcast on the main bus when the user picks Stop & save.
    /// RecordingSession subscribes and runs the auto-stop.
    static let stopRequested = Notification.Name("Daisy.autoStopPrompt.stopRequested")
    /// Broadcast when the user picks "10 more minutes".
    static let snooze10Requested = Notification.Name("Daisy.autoStopPrompt.snooze10Requested")
    /// Broadcast when the user picks "30 more minutes".
    static let snooze30Requested = Notification.Name("Daisy.autoStopPrompt.snooze30Requested")

    static func register() {
        let center = UNUserNotificationCenter.current()
        let stop = UNNotificationAction(
            identifier: actionStop,
            title: "Stop & save",
            options: [.foreground, .destructive]
        )
        let snooze10 = UNNotificationAction(
            identifier: actionSnooze10,
            title: String(localized: "10 more minutes"),
            options: []
        )
        let snooze30 = UNNotificationAction(
            identifier: actionSnooze30,
            title: String(localized: "30 more minutes"),
            options: []
        )
        let category = UNNotificationCategory(
            identifier: categoryID,
            actions: [stop, snooze10, snooze30],
            intentIdentifiers: [],
            options: []
        )
        // Merge with whatever's already registered (silence prompt,
        // auto-start, auto-stop) rather than replacing —
        // setNotificationCategories is destructive otherwise.
        center.getNotificationCategories { existing in
            var merged = existing
            merged.insert(category)
            center.setNotificationCategories(merged)
        }
    }

    /// Surface the ask. `meetingTitle` shows in the body so the user
    /// knows which meeting looks finished. Denied/ephemeral is a
    /// silent no-op — the in-app toast posted by the caller carries
    /// the question instead.
    static func post(meetingTitle: String) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted {
                        Task { @MainActor in addRequest(title: meetingTitle) }
                    }
                }
            case .authorized, .provisional:
                Task { @MainActor in addRequest(title: meetingTitle) }
            case .denied, .ephemeral:
                break
            @unknown default:
                break
            }
        }
    }

    static func cancel() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [requestID])
        center.removeDeliveredNotifications(withIdentifiers: [requestID])
    }

    private static func addRequest(title: String) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Meeting seems over")
        content.body = title.isEmpty
            ? String(localized: "Stop & save the recording, or keep going?")
            : String(localized: "Stop & save \"\(title)\", or keep going?")
        content.sound = .default
        content.categoryIdentifier = categoryID
        let request = UNNotificationRequest(
            identifier: requestID,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
