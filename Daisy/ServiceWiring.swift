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

    /// Enable or disable foreground-app meeting auto-detection.
    /// Auto-start only *starts* a session — if one is already in
    /// progress, `RecordingSession.start()` itself is the guard.
    static func applyMeetingAutoStart(enabled: Bool, session: RecordingSession) {
        if enabled {
            MeetingDetector.shared.start { [weak session] _ in
                Task { await session?.start() }
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
        guard settings.calendarAccessGranted else {
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

    /// Convenience for full initial wiring at launch.
    static func applyAll(settings: AppSettings, session: RecordingSession) {
        applyHotkey(choice: settings.recordHotkey, session: session)
        applyMeetingAutoStart(enabled: settings.autoStartOnMeeting, session: session)
        applyCalendar(settings: settings, session: session)
    }
}
