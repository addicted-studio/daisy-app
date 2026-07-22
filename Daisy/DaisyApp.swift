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
        // Weak handle for the Quit-during-recording save path
        // (DaisyAppDelegate.applicationShouldTerminate).
        RecordingSession.current = sess
        _settings = State(wrappedValue: s)
        _session = State(wrappedValue: sess)
        _floatingPanel = State(wrappedValue: FloatingPanelController(session: sess, settings: s))

        // Initial wiring of hotkey + meeting auto-start + calendar.
        // Re-applied reactively in MainView's .onChange handlers when
        // the user flips the relevant setting. Centralised in
        // `ServiceWiring` so both call sites can't drift apart.
        ServiceWiring.applyAll(settings: s, session: sess)

        // Light the sidebar "update available" badge shortly after launch
        // instead of waiting for Sparkle's next scheduled automatic check.
        // Silent (no UI); self-guards on the auto-check preference + a 1h
        // throttle so rapid relaunches don't re-poll the appcast.
        SparkleUpdater.shared.refreshAvailableUpdateSilently()
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
                Divider()
                // Tester feedback channel: collects the last 24 h of
                // Daisy's own logs + an environment header and opens
                // a pre-addressed Mail compose — the user reviews and
                // presses Send themselves (LogReporter.swift).
                Button("Send Log Report…") {
                    LogReporter.sendReport(settings: settings)
                }
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
            // ⌘R — refresh the home meeting list on demand (user
            // feedback: a meeting added in Calendar right before
            // hitting Record shouldn't have to wait for the next
            // EventKit change notification / periodic tick). Sits in
            // the View menu per macOS convention (Mail/Finder ⌘R-ish
            // refresh affordances). Safe while recording — refresh()
            // only rebuilds `upcomingMeetings`, it never touches the
            // live session.
            CommandGroup(after: .sidebar) {
                Divider()
                Button("Refresh Meetings") {
                    CalendarService.shared.refresh()
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
        }

        // Menu-bar icon — ONE MenuBarExtra, `.window` style. Clicking it
        // opens a popover whose CONTENT branches on "Compact menu bar":
        //  • Default    → full ContentView (live record + transcription).
        //  • Compact ON → CompactMenuView: just the quick actions, so the
        //    transcription mini-window never shows.
        // The branch lives in the content (ViewBuilder), NOT at the scene
        // level — `SceneBuilder` rejects if/else, so two conditional
        // MenuBarExtra scenes won't compile. Content branching updates live
        // when the toggle flips; Dock icon + app menus stay untouched.
        MenuBarExtra {
            if settings.compactMenuBarOnly {
                CompactMenuView(session: session, settings: settings)
            } else {
                ContentView(session: session, settings: settings)
                    .frame(width: 420, height: 580)
            }
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

// MARK: - Compact menu-bar popover
//
// Menu-bar popover content when "Compact menu bar" is on — the quick
// actions from ContentView's "⋯ More" menu, without the live
// transcription UI. NOTE: this is a compact POPOVER styled like a menu,
// not a true native NSMenu dropdown — SwiftUI's MenuBarExtra can't switch
// to `.menu` style conditionally, so a real dropdown would need an AppKit
// NSStatusItem. Good enough to keep the transcription window out of the way.

private struct CompactMenuView: View {
    @Bindable var session: RecordingSession
    @Bindable var settings: AppSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            row("Summarize now", "sparkles",
                disabled: session.segments.isEmpty || session.summarizer.isSummarizing) {
                Task { await session.runSummary() }
            }
            row("Open Library…", "books.vertical") {
                AppNavigation.shared.section = .library
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            row("Settings…", "gear") {
                AppNavigation.shared.section = .settings
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }

            Divider().padding(.vertical, 4)

            row("New recording", "plus.circle",
                disabled: session.status == .recording) {
                session.reset()
            }
            row("Check for Updates…", "arrow.down.circle",
                disabled: !SparkleUpdater.shared.canCheckForUpdates) {
                SparkleUpdater.shared.checkForUpdates()
            }

            Divider().padding(.vertical, 4)

            row("Quit Daisy", "power") {
                NSApp.terminate(nil)
            }
        }
        .padding(6)
        .frame(width: 240)
    }

    @ViewBuilder
    private func row(_ title: String, _ icon: String,
                     disabled: Bool = false,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
                Text(title)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}
