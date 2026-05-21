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
        content.title = "Recording started"
        content.body = title.isEmpty
            ? "Daisy is now recording your scheduled meeting."
            : "Daisy is now recording \"\(title)\"."
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
        content.title = "Meeting ended"
        content.body = title.isEmpty
            ? "Recording saved."
            : "Recording for \"\(title)\" saved."
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
