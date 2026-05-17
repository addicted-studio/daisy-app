//
//  MainView.swift
//  Daisy
//
//  Single-window primary UI. NavigationSplitView with three sections in
//  the sidebar (Home / History / Settings) and the matching content in
//  the detail pane. Replaces the previous multi-window setup where
//  History and Settings each had their own Window scene.
//
//  Section selection is held in `AppNavigation.shared` so that other
//  surfaces (menu bar popover, floating widget) can route to a section
//  via:
//      AppNavigation.shared.section = .history
//      openWindow(id: "main")
//

import EventKit
import SwiftUI

// MARK: - Section enum

enum MainSection: String, Hashable, CaseIterable, Identifiable, Sendable {
    case home, history, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home:     "Home"
        case .history:  "History"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .home:     "house"
        case .history:  "list.bullet.rectangle"
        case .settings: "gearshape"
        }
    }
}

// MARK: - Shared navigation state

@Observable
@MainActor
final class AppNavigation {
    static let shared = AppNavigation()
    var section: MainSection = .home
    private init() {}
}

// MARK: - MainView

struct MainView: View {
    @Bindable var session: RecordingSession
    @Bindable var settings: AppSettings
    @Bindable var nav = AppNavigation.shared
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var sidebarSelection: MainSection? = .home

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            detail
        }
        // Brand pill goes into `.principal` placement — that lives
        // over the detail pane centre, NOT over the sidebar's
        // leading zone. The previous `.navigation` placement was
        // physically occupying the slot where macOS would otherwise
        // extend the sidebar's frosted material up to the window's
        // top edge.
        //
        // Empty navigation title suppresses the system-rendered
        // "Daisy" text that would otherwise show on the leading
        // edge alongside our principal pill — we already provide
        // the title via the pill itself.
        .navigationTitle("")
        .toolbar {
            // Leading placement on the detail-pane toolbar (right
            // after the sidebar's right edge). Native macOS apps
            // like Notes / Finder put back/forward buttons here.
            // Previously this caused sidebar-to-top breakage — but
            // that was driven by `.toolbarBackground(.visible)`,
            // which is now removed. With the AppKit title-bar
            // transparency in DaisyAppDelegate, leading-placement
            // items don't push sidebar down.
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 7) {
                    DaisyMark(size: 14, tint: .primary)
                    Text("Daisy")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                // Inner padding sits inside the auto-fitted Liquid
                // Glass brand pill — bumped from 6 → 12 so the
                // mark + wordmark have room from the pill's left
                // and right edges instead of hugging them.
                .padding(.horizontal, 12)
            }
        }
        // `.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)`
        // (NOT `.visible` — `.visible` paints a solid bar that
        // breaks sidebar-to-top). `.hidden` tells macOS 26 NOT to
        // composite its Liquid Glass material under the toolbar,
        // which is what was leaving white strips around toolbar
        // items + in the fullscreen aux-toolbar window. Window's
        // own `backgroundColor` (cream, set in DaisyAppDelegate)
        // then shows through cleanly.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .frame(minWidth: 860, minHeight: 560)
        // Warm ivory window background — matches mydaisy.io and
        // defeats macOS's default cool-gray windowBackgroundColor.
        // `containerBackground(_:for: .window)` (macOS 14+) tints the
        // window's content area; sidebar's frosted material still
        // composes on top of this, which gives a coherent warm tone
        // throughout. Recording orange + cinnamon accents land much
        // better on this base than on system gray.
        .containerBackground(Color.daisyBgPrimary, for: .window)
        // Apply soft-cinnamon tint at the NavigationSplitView root.
        // Putting it deeper (on the inner List) didn't propagate to
        // macOS's native sidebar selection chip — that uses the
        // SwiftUI `.tint` from the nearest ancestor that owns the
        // selection style.
        .tint(Color.daisyAccentSoft)
        .modifier(ToastOverlay())
        // Keep the local sidebar selection mirrored with the shared
        // AppNavigation state so external surfaces (menu bar / widget)
        // can switch sections by mutating `AppNavigation.shared`.
        .onAppear { sidebarSelection = nav.section }
        .onChange(of: sidebarSelection) { _, new in
            if let new, new != nav.section { nav.section = new }
        }
        .onChange(of: nav.section) { _, new in
            if sidebarSelection != new { sidebarSelection = new }
        }
        // Reactive re-wiring when the user changes the hotkey or
        // flips auto-start in Settings. Initial wiring is done in
        // DaisyApp.init via the same ServiceWiring helpers so the
        // two call sites can't drift apart.
        .onChange(of: settings.recordHotkey) { _, new in
            ServiceWiring.applyHotkey(choice: new, session: session)
        }
        .onChange(of: settings.autoStartOnMeeting) { _, enabled in
            ServiceWiring.applyMeetingAutoStart(enabled: enabled, session: session)
        }
        .onChange(of: settings.autoStartFromCalendar) { _, _ in
            ServiceWiring.applyCalendar(settings: settings, session: session)
        }
        // When EventKit's authorisation status flips (typically via
        // the system prompt fired from Home's Connect button or from
        // Settings), mirror it into AppSettings and re-apply the
        // wiring with the proper auto-start handler.
        .onChange(of: CalendarService.shared.authorizationStatus) { _, status in
            let granted = (status == .fullAccess)
            if settings.calendarAccessGranted != granted {
                settings.calendarAccessGranted = granted
            }
            ServiceWiring.applyCalendar(settings: settings, session: session)
        }
        .onChange(of: settings.mcpServerEnabled) { _, _ in
            ServiceWiring.applyMCPServer(settings: settings)
        }
        .onChange(of: settings.mcpServerPort) { _, _ in
            // Re-apply when the port changes, but only if the server
            // is currently enabled — otherwise editing the port
            // shouldn't side-effect a stopped server.
            if settings.mcpServerEnabled {
                ServiceWiring.applyMCPServer(settings: settings)
            }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $sidebarSelection) {
            Section {
                ForEach(MainSection.allCases) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .tag(section)
                }
            }

            // Recording capsule sits directly under nav items, no
            // section header — header label was visual noise.
            Section {
                RecordCapsule(session: session)
                    // Match the horizontal insets of List(.sidebar)
                    // rows so the capsule lines up exactly with the
                    // Home / History / Settings highlight chips
                    // above it. Zero leading/trailing here lets the
                    // capsule's own internal padding define the
                    // visual width, identical to how Label rows
                    // render in macOS sidebar.
                    .listRowInsets(EdgeInsets(top: 14, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.sidebar)
        // Override system blue → soft cinnamon. macOS uses `.tint`
        // for List row selection fills, focus rings, and `Label`
        // icon colour in `.sidebar` style.
        .tint(Color.daisyAccentSoft)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 6) {
                DaisyMark(size: 14, tint: .secondary)
                Text("Daisy")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("v\(appVersion)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch nav.section {
        case .home:
            HomeView(session: session)
        case .history:
            HistoryView()
        case .settings:
            SettingsView(settings: settings)
        }
    }
}
