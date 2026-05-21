//
//  SystemPermissions.swift
//  Daisy
//
//  Single observable façade over the four macOS privacy permissions
//  Daisy interacts with: Microphone, Calendar, Accessibility, Screen
//  Recording. Used by the Connections → Permissions tab so users can
//  see what's granted, request what isn't, and open System Settings
//  for what was previously denied.
//
//  ─── Why centralise this ──────────────────────────────────────────
//
//  Each permission has its own API surface — `AVCaptureDevice` for
//  mic, `EKEventStore` for Calendar, `AXIsProcessTrusted` for
//  Accessibility, `CGPreflightScreenCaptureAccess` for Screen
//  Recording — and the UI on every screen that cares about them used
//  to call them ad-hoc. This service:
//    • polls all four on construction and on app focus, so the UI
//      reflects external changes (user toggling in System Settings);
//    • exposes a unified `Status` enum so the view layer can switch
//      uniformly without converting AVAuthorizationStatus vs
//      EKAuthorizationStatus vs raw Bool;
//    • provides `request…()` and `openSettings…()` per service so
//      the row UI is just "iconName + title + status + button".
//
//  ─── Hardened Runtime gotcha (debugged 2026-05-20) ────────────────
//
//  Calendar prompt was silently rejected by tccd for hours until we
//  realised macOS Hardened Runtime requires
//  `com.apple.security.personal-information.calendars` in entitlements
//  even when App Sandbox is OFF. Same is true of `.addressbook`,
//  `.photos-library`, `.reminders`, `.location`. Mic / Accessibility /
//  Screen Recording do NOT require entitlements under non-sandboxed
//  Hardened Runtime — only Info.plist usage strings. See
//  `Daisy/Daisy.entitlements` for the canonical comment.
//

import Foundation
import Observation
import AVFoundation
import EventKit
import ApplicationServices
import CoreGraphics
import AppKit
@preconcurrency import UserNotifications

@MainActor
@Observable
final class SystemPermissions {
    static let shared = SystemPermissions()

    /// Uniform status across services. Each native API has its own
    /// enum (with subtly different cases — `writeOnly`, `restricted`,
    /// etc.) so we normalise here.
    enum Status: Sendable, Equatable {
        /// User has not yet been asked. `request…()` will show the
        /// system prompt.
        case notDetermined
        /// Granted, app can use the service freely.
        case granted
        /// User explicitly denied. Only path forward is System
        /// Settings → toggle ON.
        case denied
        /// Macros-level restriction (managed device, parental
        /// controls). Cannot be granted from this app.
        case restricted
        /// Calendar-specific: user picked "write only" instead of
        /// full access. Treat as insufficient for Daisy (we only
        /// READ events).
        case insufficient
    }

    /// Microphone — required for any recording.
    private(set) var microphone: Status = .notDetermined
    /// Calendar — optional, only needed for auto-start on meetings.
    private(set) var calendar: Status = .notDetermined
    /// Accessibility — required for the dictation mode's ⌘V
    /// auto-paste into the active app via `CGEvent.post`.
    private(set) var accessibility: Status = .notDetermined
    /// Screen Recording — optional, only needed for capturing the
    /// "other side" of meetings (system audio out of Zoom / Meet etc).
    private(set) var screenRecording: Status = .notDetermined

    /// UserDefaults key used to remember that we've already asked
    /// once for Screen Recording. macOS gives us no way to distinguish
    /// "never asked" from "explicitly denied" via `CGPreflightScreenCaptureAccess`
    /// — both return `false`. We track the request ourselves so the
    /// UI can show "Open Settings…" after the first attempt instead of
    /// re-offering a "Request" button that won't actually re-prompt.
    private static let hasRequestedScreenRecordingKey = "daisy.permissions.hasRequestedScreenRecording"
    /// Notifications — optional. Required for the auto-start /
    /// auto-stop banners and the long-silence prompt. Daisy keeps
    /// recording without it; the user just doesn't get the macOS
    /// banner nudges.
    private(set) var notifications: Status = .notDetermined

    init() {
        refresh()
        // Re-check whenever the app comes back to foreground. macOS
        // doesn't push permission-change notifications; polling on
        // focus is the standard pattern (the user almost always
        // grants by going to System Settings → coming back to us).
        //
        // No deinit / observer cleanup — `SystemPermissions.shared`
        // is a process-lifetime singleton, so the observer is
        // intentionally never removed. Avoids Swift 6 MainActor /
        // nonisolated deinit headaches.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    /// Re-read all four statuses from the system. Idempotent; safe to
    /// call from `.onAppear`, focus notification, after a `request`
    /// call returns, etc.
    func refresh() {
        microphone = Self.normalise(AVCaptureDevice.authorizationStatus(for: .audio))
        calendar = Self.normalise(EKEventStore.authorizationStatus(for: .event))
        accessibility = AXIsProcessTrusted() ? .granted : .notDetermined
        // Screen Recording: preflight gives a Bool but can't tell
        // "never asked" from "denied". We track the request locally
        // and surface `.denied` after the first attempt so the UI
        // routes the user to System Settings instead of looping on
        // a Request button that no longer triggers a prompt.
        let preflight = CGPreflightScreenCaptureAccess()
        if preflight {
            screenRecording = .granted
        } else {
            let hasRequested = UserDefaults.standard.bool(forKey: Self.hasRequestedScreenRecordingKey)
            screenRecording = hasRequested ? .denied : .notDetermined
        }
        refreshNotificationsAsync()
    }

    /// `UNUserNotificationCenter.getNotificationSettings` is async-
    /// callback-only (no sync accessor). Fire and forget; the next
    /// SwiftUI render will pick up the updated value via @Observable.
    /// Called from `refresh()` plus right after `requestNotifications`.
    private func refreshNotificationsAsync() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status: Status
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: status = .granted
            case .denied: status = .denied
            case .notDetermined: status = .notDetermined
            @unknown default: status = .notDetermined
            }
            Task { @MainActor in
                SystemPermissions.shared.notifications = status
            }
        }
    }

    // MARK: - Request

    /// Trigger the system mic prompt if `notDetermined`. No-op otherwise.
    func requestMicrophone() async {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        refresh()
    }

    /// Trigger the system calendar prompt via the existing
    /// `CalendarService` flow (which has the foreground-window
    /// activation + fresh-store handling we needed for Hardened
    /// Runtime to actually surface the dialog).
    func requestCalendar() async {
        _ = await CalendarService.shared.requestAccess()
        refresh()
    }

    /// Show the system Accessibility prompt. `AXIsProcessTrustedWithOptions`
    /// with `kAXTrustedCheckOptionPrompt=true` is the canonical API
    /// — there's no async/completion variant. The user is sent to
    /// System Settings; we'll see the state update on next focus.
    func requestAccessibility() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        // No refresh here — the dialog is async and the state won't
        // flip until the user has clicked through System Settings.
    }

    /// Trigger the system Screen Recording prompt.
    ///
    /// `CGRequestScreenCaptureAccess()` is documented to show the
    /// system dialog AND register Daisy in System Settings → Privacy
    /// → Screen Recording. In practice on macOS 14+ it has become
    /// **unreliable** — the prompt frequently does NOT appear and the
    /// function returns `false` immediately (multiple developer
    /// reports, FB14529739 et al). The user clicks "Request", nothing
    /// happens, the button stays "Request" — a dead end.
    ///
    /// Two-pronged fix:
    ///   1. Persist that we've asked at least once. `refresh()` now
    ///      maps a still-not-granted state to `.denied` instead of
    ///      `.notDetermined`, so the UI shows "Open Settings…" next
    ///      time instead of "Request".
    ///   2. If the call returned `false` (either the prompt didn't
    ///      fire, or it did and the user said No), open System
    ///      Settings → Privacy → Screen Recording directly. The user
    ///      always has a path forward.
    ///
    /// Trade-off: if the system prompt DID appear and the user
    /// intentionally clicked "Deny", they'll be bounced to System
    /// Settings as well. Acceptable friction — they can just close
    /// the Settings window if they meant the Deny.
    func requestScreenRecording() {
        UserDefaults.standard.set(true, forKey: Self.hasRequestedScreenRecordingKey)
        let granted = CGRequestScreenCaptureAccess()
        if !granted {
            openScreenRecordingSettings()
        }
        refresh()
    }

    /// Show the system Notifications prompt. macOS responds async;
    /// the new state lands in `notifications` via
    /// `refreshNotificationsAsync()` after the user clicks through.
    func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { _, _ in
            Task { @MainActor in
                SystemPermissions.shared.refreshNotificationsAsync()
            }
        }
    }

    // MARK: - Open Settings deeplinks

    func openMicrophoneSettings()    { openPrivacyPane("Privacy_Microphone") }
    func openCalendarSettings()      { openPrivacyPane("Privacy_Calendars") }
    func openAccessibilitySettings() { openPrivacyPane("Privacy_Accessibility") }
    func openScreenRecordingSettings() { openPrivacyPane("Privacy_ScreenCapture") }
    /// Notifications-specific deeplink — macOS x-apple URL targets
    /// the per-app Notifications pane directly.
    func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else { return }
        NSWorkspace.shared.open(url)
    }

    private func openPrivacyPane(_ anchor: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Aggregate predicates (for badges + "needs attention")

    /// Required permissions Daisy cannot operate without:
    /// • Microphone — no recording at all.
    /// • Accessibility — dictation mode's auto-paste fails silently.
    var hasAllRequiredGranted: Bool {
        microphone == .granted && accessibility == .granted
    }

    /// True if any required permission is missing — drives the
    /// "needs attention" indicator on Home.
    var needsAttention: Bool {
        microphone != .granted || accessibility != .granted
    }

    /// Optional permissions — Daisy still works without these but
    /// some features degrade (no auto-start, mic-only meeting audio).
    var hasAllOptionalGranted: Bool {
        calendar == .granted && screenRecording == .granted
    }

    // MARK: - Helpers

    private static func normalise(_ s: AVAuthorizationStatus) -> Status {
        switch s {
        case .notDetermined: return .notDetermined
        case .authorized:    return .granted
        case .denied:        return .denied
        case .restricted:    return .restricted
        @unknown default:    return .notDetermined
        }
    }

    private static func normalise(_ s: EKAuthorizationStatus) -> Status {
        switch s {
        case .notDetermined: return .notDetermined
        case .fullAccess:    return .granted
        case .denied:        return .denied
        case .restricted:    return .restricted
        case .writeOnly:     return .insufficient
        @unknown default:    return .notDetermined
        }
    }
}
