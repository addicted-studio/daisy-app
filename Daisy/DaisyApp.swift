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
        // One-shot migration of legacy `hola.*` preference keys to
        // `daisy.*`. Must run BEFORE AppSettings is constructed so the
        // migrated values are read in this same launch.
        UserDefaultsMigration.runIfNeeded()

        let s = AppSettings()
        let sess = RecordingSession(settings: s)
        _settings = State(wrappedValue: s)
        _session = State(wrappedValue: sess)
        _floatingPanel = State(wrappedValue: FloatingPanelController(session: sess, settings: s))

        // Initial wiring of hotkey + meeting auto-start + calendar.
        // Re-applied reactively in MainView's .onChange handlers when
        // the user flips the relevant setting. Centralised in
        // `ServiceWiring` so both call sites can't drift apart.
        ServiceWiring.applyAll(settings: s, session: sess)
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
        .commands {
            // Re-target the system "Daisy Help" menu item at our
            // hosted support page instead of the default (which
            // would look for a bundled .help file we don't ship).
            CommandGroup(replacing: .help) {
                Button("Daisy Help") {
                    if let url = URL(string: "https://mydaisy.io/support") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .keyboardShortcut("?", modifiers: [.command])
            }
            // Replace the default About panel with one that names the
            // studio and links to contact + website. The system's
            // default shows just the bundle version, which reads as
            // "we forgot to fill this in".
            CommandGroup(replacing: .appInfo) {
                Button("About Daisy") {
                    AboutPanel.show()
                }
                // "Check for Updates…" sits in the App menu directly
                // under About — that's the macOS convention (Slack,
                // Bear, Tot, MailMate all put it there). The button is
                // disabled while an in-flight check is running so a
                // double-click can't fire two probes; the wrapper also
                // disables it entirely when Sparkle isn't linked yet,
                // which is the state on the first build before the
                // SPM dep is added in Xcode.
                Button("Check for Updates…") {
                    SparkleUpdater.shared.checkForUpdates()
                }
                .disabled(!SparkleUpdater.shared.canCheckForUpdates)
            }
        }

        MenuBarExtra {
            ContentView(session: session, settings: settings)
                .frame(width: 420, height: 580)
        } label: {
            MenuBarLabel(session: session, settings: settings)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Menu bar label
//
// Pulls the dynamic label content out of DaisyApp's scene builder
// so we can `@Bindable` the session + calendar service and update
// the label whenever either changes. Three states:
//
//   • Recording  → icon only (the existing menu-bar art already
//                  communicates "active"; adding text would crowd
//                  the system bar at the worst time)
//   • Setting on AND has upcoming event within 8h
//                → icon + "14:30 · Q3 Review"
//   • Default    → icon only
//

private struct MenuBarLabel: View {
    @Bindable var session: RecordingSession
    @Bindable var settings: AppSettings
    @Bindable private var calendar = CalendarService.shared

    var body: some View {
        if let next = nextMeetingLabel {
            HStack(spacing: 4) {
                Image(nsImage: DaisyMark.menuBarImage)
                Text(next)
            }
        } else {
            Image(nsImage: DaisyMark.menuBarImage)
        }
    }

    /// Returns the menu-bar label text when ALL conditions hold:
    ///   • User opted in (`menuBarShowsNextMeeting == true`)
    ///   • Session is NOT actively recording (recording state owns
    ///     the menu bar — surfacing "Next meeting" mid-recording is
    ///     a distraction)
    ///   • Calendar service has an upcoming event within 8 hours
    /// nil → fall back to icon-only.
    private var nextMeetingLabel: String? {
        guard settings.menuBarShowsNextMeeting else { return nil }
        switch session.status {
        case .recording, .paused, .preparing, .stopping, .summarizing:
            return nil
        case .idle, .finished, .failed:
            return calendar.nextMeetingShortLabel
        }
    }
}
