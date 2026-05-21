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
//      AppNavigation.shared.section = .library
//      openWindow(id: "main")
//

import EventKit
import SwiftUI

// MARK: - Section enum

enum MainSection: String, Hashable, CaseIterable, Identifiable, Sendable {
    case home, library, connections, settings, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home:        "Home"
        case .library:     "Library"
        case .connections: "Connections"
        case .settings:    "Settings"
        case .about:       "About"
        }
    }

    var systemImage: String {
        switch self {
        case .home:        "house"
        // books.vertical reads as "your shelf of past meetings" —
        // matches Apple Books / Music's Library iconography. Was
        // `list.bullet.rectangle` while the section was called
        // History, which framed it as a chronological log; Library
        // reframes it as a curated collection, and the icon follows.
        case .library:     "books.vertical"
        // arrow.triangle.branch reads as "things diverging from a
        // central point" — same shape Notion / Linear / Raycast use
        // for their Integrations / Connections nav entries. Closest
        // SF Symbol to that visual without falling back to the
        // generic link icon (which we already use elsewhere).
        case .connections: "arrow.triangle.branch"
        case .settings:    "gearshape"
        case .about:       "info.circle"
        }
    }
}

// MARK: - Shared navigation state

/// SwiftUI TabView in SettingsView has no public selection by
/// default. Exposing the tab enum here lets external surfaces
/// (FirstRun CTAs, Home-screen hints) deep-link to a specific
/// settings sub-tab, not just "Settings" in the sidebar.
///
/// `.integrations` and `.mcpServer` were moved out of Settings into
/// the top-level `Connections` sidebar destination (see
/// `ConnectionSection`). Settings now holds only the "how the
/// recorder works" tabs — Capture / Transcription / Summary.
enum SettingsTab: String, Hashable, Sendable {
    /// General is the catch-all tab — audio I/O devices, sounds,
    /// hotkey, calendar gating, screenshot toggles, the floating
    /// widget, storage location. Was named `.capture` while it sat
    /// alongside Notion / MCP / Integrations tabs, but those moved
    /// to the top-level Connections destination and what remained
    /// drifted toward "general app preferences" — hence the rename.
    case general
    case transcription
    case summary
    /// System privacy permissions Daisy interacts with — Microphone,
    /// Calendar, Accessibility, Screen Recording. Lives in Settings
    /// (not Connections) because it's about local OS-level access,
    /// not about external service integrations. macOS convention —
    /// Granola, Wispr Flow et al. put permission dashboards here too.
    case permissions
}

/// Sub-section inside the Connections page. Lets external CTAs
/// (FirstRun, Home destination prompts) deep-link to a specific
/// card on the page — MCP server / Auto-routing.
///
/// Calendar dropped in 1.0.4 — EventKit permission moved to
/// Settings → Permissions and behaviour toggles to Settings →
/// General. Notion dropped in 1.0.5 — destination of the same
/// class as the sessions folder, so it lives in Settings → General
/// → Storage now (inline DisclosureGroup for advanced fields).
/// Google Calendar OAuth UI is dormant pre-verification; when it
/// returns it'll come back as its own case here.
enum ConnectionSection: String, Hashable, Sendable {
    case mcpServer
    case autoRouting
}

@Observable
@MainActor
final class AppNavigation {
    static let shared = AppNavigation()
    var section: MainSection = .home
    /// One-shot session selection request. HomeView (and any other
    /// surface that needs to deep-link into a transcript) sets this
    /// together with `section = .library`; LibraryView consumes and
    /// clears it on appear / when it observes the change. nil means
    /// "let the view pick its own default" — usually the first row.
    var pendingLibrarySelection: StoredSession.ID?
    /// One-shot Settings tab request. FirstRunView and any external
    /// CTA that wants to land the user on a specific sub-tab inside
    /// SettingsView (Summary for API key, Capture for Calendar,
    /// etc.) sets this together with `section = .settings`. The
    /// SettingsView reads + clears it on appear. nil means "use the
    /// default tab".
    var pendingSettingsTab: SettingsTab?
    /// One-shot Connections deep-link. Same pattern as
    /// `pendingSettingsTab` but for the new Connections sidebar
    /// destination. ConnectionsView reads + clears on appear; the
    /// section scrolls to the matching anchor.
    var pendingConnectionsSection: ConnectionSection?
    private init() {}

    /// Convenience for `Open this session in Library`. Sets both
    /// section and the pending selection so the Library view jumps
    /// straight to the correct row.
    func openInLibrary(_ id: StoredSession.ID) {
        pendingLibrarySelection = id
        section = .library
    }

    /// Convenience for `Open Settings → <tab>`. FirstRun + onboarding
    /// CTAs use this so the user lands exactly where the action they
    /// just read about is configured, not on the default General tab.
    func openInSettings(_ tab: SettingsTab) {
        pendingSettingsTab = tab
        section = .settings
    }

    /// Convenience for `Open Connections → <card>`. Used by FirstRun
    /// onboarding CTAs ("Connect Notion", "Set up MCP server") and
    /// the Home destination-discovery banner.
    func openInConnections(_ card: ConnectionSection) {
        pendingConnectionsSection = card
        section = .connections
    }
}

// MARK: - MainView

struct MainView: View {
    @Bindable var session: RecordingSession
    @Bindable var settings: AppSettings
    @Bindable var nav = AppNavigation.shared
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var sidebarSelection: MainSection? = .home
    /// Mirrors `settings.hasShownFirstRun` for the sheet binding.
    /// We can't bind `.sheet(isPresented:)` directly to the
    /// settings boolean because we want "show when false" — easier
    /// to derive a local flipped state and write through on
    /// dismiss inside `FirstRunView`.
    @State private var showFirstRun: Bool = false

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
        .daisyWindowToolbarHidden()
        .frame(minWidth: 860, minHeight: 560)
        // Warm ivory window background — matches mydaisy.io and
        // defeats macOS's default cool-gray windowBackgroundColor.
        // `containerBackground(_:for: .window)` (macOS 14+) tints the
        // window's content area; sidebar's frosted material still
        // composes on top of this, which gives a coherent warm tone
        // throughout. Recording orange + cinnamon accents land much
        // better on this base than on system gray.
        .daisyWindowBackground(Color.daisyBgPrimary)
        // Apply soft-cinnamon tint at the NavigationSplitView root.
        // Putting it deeper (on the inner List) didn't propagate to
        // macOS's native sidebar selection chip — that uses the
        // SwiftUI `.tint` from the nearest ancestor that owns the
        // selection style.
        .tint(Color.daisyAccentSoft)
        .modifier(ToastOverlay())
        // First-run sheet — fired once via .onAppear (not on every
        // view re-render). After dismiss, `FirstRunView` flips
        // `settings.hasShownFirstRun = true` so the sheet doesn't
        // reappear on next launch.
        .sheet(isPresented: $showFirstRun) {
            FirstRunView(settings: settings)
        }
        .onAppear {
            if !settings.hasShownFirstRun {
                showFirstRun = true
            }
        }
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
        .onChange(of: settings.recordHotkey) { _, _ in
            ServiceWiring.applyAllHotkeys(settings: settings, session: session)
        }
        .onChange(of: settings.voiceNoteHotkey) { _, _ in
            ServiceWiring.applyAllHotkeys(settings: settings, session: session)
        }
        .onChange(of: settings.dictationHotkey) { _, _ in
            ServiceWiring.applyAllHotkeys(settings: settings, session: session)
        }
        // Granola-style auto-open: when a session finishes and the
        // user opted in via `settings.showSessionAfterStop`, jump
        // to History and deep-link to the just-recorded row.
        // RecordingSession.stop() does a synchronous
        // SessionStore.refresh() before flipping to .finished, so
        // by the time this handler fires the row is in the list
        // and LibraryView's pending-selection handler can land on it.
        .onChange(of: session.status) { _, new in
            if case .finished = new,
               settings.showSessionAfterStop,
               let id = session.sessionDirectory?.lastPathComponent {
                AppNavigation.shared.openInLibrary(id)
            }
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
        // Mirror Google Calendar OAuth connect/disconnect — when
        // user signs in/out via Settings, re-run CalendarService
        // wiring so its poll timer + meeting-start handler reflect
        // the new source state (start when newly available, stop
        // when both EventKit and Google are gone).
        .onChange(of: GoogleAccountStore.shared.isConnected) { _, _ in
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

                // System-audio status row — visible during active
                // recording so the user can see at a glance whether
                // the OTHER side of the meeting is being captured.
                // Tap the deny-state pill to jump to Privacy
                // Settings. Hidden in normal capturing-OK state on
                // .capturing? No — we want a positive confirmation
                // pill too, so the user trusts what they're seeing.
                if session.status == .recording || session.status == .paused {
                    SystemAudioStatusPill(session: session)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))
                        .listRowBackground(Color.clear)
                }

                // Stop & save lives next to the toggle capsule so a
                // user mid-session can finalise without hunting in
                // the kebab menu. Only shows during recording / paused.
                if session.status == .recording || session.status == .paused {
                    Button {
                        Task { await session.stop() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "stop.fill")
                                .font(.callout.weight(.semibold))
                            Text("Stop & save")
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .foregroundStyle(Color.daisyTextPrimary)
                        .background(
                            Capsule(style: .continuous).fill(Color.daisyBgElevated)
                        )
                        .overlay(
                            Capsule(style: .continuous).strokeBorder(Color.daisyDivider, lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))
                    .listRowBackground(Color.clear)
                }
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
        case .library:
            LibraryView()
        case .connections:
            ConnectionsView(settings: settings)
        case .settings:
            SettingsView(settings: settings)
        case .about:
            AboutView()
        }
    }
}

// MARK: - System audio status pill

/// Tiny status row that appears in the sidebar during active
/// recording, showing whether the OTHER side of the meeting is
/// being captured. The three states a user actually cares about:
///
///   • capturing — green dot, "Other side: capturing"
///   • denied    — orange warning + "Open Settings" deeplink
///   • failed    — orange warning with the underlying error
///
/// The `.disabled` and `.pending` states render nothing — the
/// user either turned it off on purpose, or recording hasn't
/// started yet (in which case the pill row is hidden upstream).
private struct SystemAudioStatusPill: View {
    @Bindable var session: RecordingSession

    var body: some View {
        switch session.systemAudioStatus {
        case .capturing:
            capturingPill
        case .denied:
            deniedPill
        case .failed(let message):
            failedPill(message)
        case .disabled, .pending:
            EmptyView()
        }
    }

    private var capturingPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.daisySuccess)
                .frame(width: 6, height: 6)
            Text("Other side: capturing")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var deniedPill: some View {
        Button {
            ScreenRecordingPermission.openSystemSettings()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.daisyWarning)
                Text("Other side: off")
                    .font(.caption)
                    .foregroundStyle(Color.daisyTextPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("Fix")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.daisyAccent)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous).fill(Color.daisyWarning.opacity(0.10))
            )
            .overlay(
                Capsule(style: .continuous).strokeBorder(Color.daisyWarning.opacity(0.25), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .help("Screen Recording permission is required to capture the other side of meetings. Click to open System Settings.")
    }

    private func failedPill(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(Color.daisyWarning)
            Text("Other side: off")
                .font(.caption)
                .foregroundStyle(Color.daisyTextPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous).fill(Color.daisyWarning.opacity(0.10))
        )
        .overlay(
            Capsule(style: .continuous).strokeBorder(Color.daisyWarning.opacity(0.25), lineWidth: 0.5)
        )
        .help(message)
    }
}
