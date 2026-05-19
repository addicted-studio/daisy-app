//
//  ServiceWiring.swift
//  Daisy
//
//  Single source of truth for wiring shared services (HotkeyManager,
//  MeetingDetector, CalendarService) to the current `RecordingSession`
//  and `AppSettings`. Called from two places:
//
//   1. `DaisyApp.init` — initial wiring at launch, so hotkeys + auto-
//      start work before the user opens the window.
//   2. `MainView` `.onChange` handlers — re-applied when the user flips
//      the relevant setting.
//
//  Centralising here prevents the two wiring sites from drifting apart
//  as services are added or their handler signatures change.
//

import Foundation

@MainActor
enum ServiceWiring {

    /// Register the global hotkey for start/stop. Idempotent — calling
    /// again replaces any previous registration. Passing a hotkey with
    /// `keyCode == nil` simply unregisters.
    static func applyHotkey(choice: HotkeyChoice, session: RecordingSession) {
        HotkeyManager.shared.register(choice: choice) { [weak session] in
            Task { await session?.toggleByHotkey() }
        }
    }

    /// Enable or disable foreground-app meeting auto-detection
    /// (NSWorkspace-based — fires when Zoom / Teams / Meet etc. is
    /// launched).
    ///
    /// We deliberately do NOT call `session.start()` when a session
    /// is already recording or paused. Previously the call slipped
    /// through to `start()` and silently returned via its guard,
    /// leaving the user confused why a brand-new meeting app launch
    /// did nothing visible. Now we surface a toast so the user can
    /// stop the previous session intentionally if they want a fresh
    /// recording for the newly-launched app.
    ///
    /// Unlike the calendar path (`startFromMeeting`) we cannot auto-
    /// rotate here — NSWorkspace's notification gives us the app
    /// bundle ID, not a `DaisyMeeting`, so we have no idea if it's
    /// a "different" meeting from what's already being recorded.
    /// Surfacing rather than acting is the right move.
    static func applyMeetingAutoStart(enabled: Bool, session: RecordingSession) {
        if enabled {
            MeetingDetector.shared.start { [weak session] appName in
                Task { @MainActor in
                    guard let session else { return }
                    if session.status == .recording || session.status == .paused {
                        ToastCenter.shared.show(
                            "\(appName) launched while Daisy is already recording — stop the current session first if you want a fresh one.",
                            style: .info
                        )
                        return
                    }
                    await session.start()
                }
            }
        } else {
            MeetingDetector.shared.stop()
        }
    }

    /// Configure CalendarService for the current permission +
    /// auto-start preference. Called both on app launch and whenever
    /// `autoStartFromCalendar` or `calendarAccessGranted` flips.
    ///
    /// Behaviour:
    ///   • No permission → stop the service.
    ///   • Permission granted → start (idempotent), passing the
    ///     auto-start preference and a meeting-start handler.
    ///   • Both branches above keep `upcomingMeetings` cache warm
    ///     for the Home view even when auto-start is off — the user
    ///     still wants to see what's coming.
    static func applyCalendar(settings: AppSettings, session: RecordingSession) {
        // CalendarService now multiplexes EventKit + Google OAuth.
        // Start the service if EITHER source is available — a
        // user might only have Google connected (no Internet
        // Accounts integration) and still want auto-start.
        let hasEventKit = settings.calendarAccessGranted
        let hasGoogle = GoogleAccountStore.shared.isConnected
        guard hasEventKit || hasGoogle else {
            CalendarService.shared.stop()
            return
        }
        CalendarService.shared.start(
            lookaheadHours: 24,
            autoStartOnMeeting: settings.autoStartFromCalendar
        ) { [weak session] meeting in
            Task { await session?.startFromMeeting(meeting) }
        }
    }

    /// Start or stop the local MCP server based on the user's
    /// preference. Loopback-only; opt-in. Idempotent.
    static func applyMCPServer(settings: AppSettings) {
        if settings.mcpServerEnabled {
            MCPServer.shared.start(port: settings.mcpServerPort)
        } else {
            MCPServer.shared.stop()
        }
    }

    /// Convenience for full initial wiring at launch.
    static func applyAll(settings: AppSettings, session: RecordingSession) {
        applyHotkey(choice: settings.recordHotkey, session: session)
        applyMeetingAutoStart(enabled: settings.autoStartOnMeeting, session: session)
        applyCalendar(settings: settings, session: session)
        applyMCPServer(settings: settings)
    }
}
