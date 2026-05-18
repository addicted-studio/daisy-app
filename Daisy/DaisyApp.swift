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
            }
        }

        MenuBarExtra {
            ContentView(session: session, settings: settings)
                .frame(width: 420, height: 580)
        } label: {
            Image(nsImage: DaisyMark.menuBarImage)
        }
        .menuBarExtraStyle(.window)
    }
}
