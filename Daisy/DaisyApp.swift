//
//  DaisyApp.swift
//  Daisy
//
//  Regular Mac app (Dock icon + Cmd+Tab) that also lives in the menu
//  bar. Single primary scene with a NavigationSplitView (Home / History
//  / Settings sections in a sidebar).
//
//  Surfaces:
//   • MainView (Window id "main") — primary window. Opens on launch
//     and on Dock-icon click. Closing it does NOT quit (see
//     DaisyAppDelegate). `Window` (singular) ensures menu-bar / widget
//     entry points focus the existing window instead of duplicating it.
//   • MenuBarExtra — full recording UI in the menu bar.
//   • FloatingPanelController — borderless petal widget over the
//     desktop while recording / summarizing.
//

import SwiftUI

@main
struct DaisyApp: App {
    @NSApplicationDelegateAdaptor(DaisyAppDelegate.self) private var appDelegate

    @State private var settings: AppSettings
    @State private var session: RecordingSession
    @State private var floatingPanel: FloatingPanelController

    init() {
        let s = AppSettings()
        let sess = RecordingSession(settings: s)
        _settings = State(wrappedValue: s)
        _session = State(wrappedValue: sess)
        _floatingPanel = State(wrappedValue: FloatingPanelController(session: sess))

        // Initial wiring of global hotkey + meeting auto-start. Both
        // are re-applied reactively in MainView's onChange handlers
        // when the user flips a setting; this initial pass makes them
        // work from app launch even before the user opens the window.
        HotkeyManager.shared.register(choice: s.recordHotkey) {
            Task { await sess.toggleByHotkey() }
        }
        if s.autoStartOnMeeting {
            MeetingDetector.shared.start { _ in
                // Auto-start only starts. If we're already recording
                // (another meeting in progress), we leave it alone —
                // `start()` itself guards on status.
                Task { await sess.start() }
            }
        }
        if s.autoStartFromCalendar && s.calendarAccessGranted {
            CalendarService.shared.start(
                lookaheadHours: 24,
                autoStartOnMeeting: true
            ) { meeting in
                Task { await sess.startFromMeeting(meeting) }
            }
        } else if s.calendarAccessGranted {
            // Permission already granted in a previous session — keep
            // the upcoming-meetings cache warm for the Home view even
            // though auto-start is off.
            CalendarService.shared.start(
                lookaheadHours: 24,
                autoStartOnMeeting: false
            ) { _ in }
        }
    }

    var body: some Scene {
        // Primary window — opens on launch and on Dock click. `Window`
        // (singular) guarantees one main window: `openWindow(id:"main")`
        // from the menu bar / widget will focus the existing window
        // instead of spawning duplicates. With macOS 14+ SwiftUI infers
        // `.regular` activation policy from having any standard
        // foreground scene, so Dock icon + Cmd+Tab still appear.
        Window("Daisy", id: "main") {
            MainView(session: session, settings: settings)
        }
        .windowResizability(.contentMinSize)
        .defaultPosition(.center)
        .defaultSize(width: 980, height: 640)
        // No `.windowToolbarStyle(.unified)` — that flag stretches the
        // toolbar bar across the entire window, painting OVER the
        // sidebar's top edge. Default NavigationSplitView behaviour
        // on macOS already lets the sidebar's frosted material
        // extend up to the title bar (Mail / Notes / Finder pattern),
        // and toolbar items live in the detail-pane portion only.

        MenuBarExtra {
            ContentView(session: session)
                .frame(width: 420, height: 580)
        } label: {
            Image(nsImage: DaisyMark.menuBarImage)
        }
        .menuBarExtraStyle(.window)
    }
}
