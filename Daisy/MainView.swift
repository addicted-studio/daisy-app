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

import AppKit
import EventKit
import SwiftUI

// MARK: - Section enum

enum MainSection: String, Hashable, CaseIterable, Identifiable, Sendable {
    case home, library, dictation, connections, settings, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home:        "Home"
        case .library:     "Library"
        case .dictation:   "Dictation"
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
        // character.cursor.ibeam reads as "type / insert text at the
        // caret" — the universal dictation/typing affordance (same
        // glyph the old Settings → Dictation tab used). Reframes this
        // section as "where your dictated words live" alongside the
        // Library of meetings.
        case .dictation:   "character.cursor.ibeam"
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
    /// Recording behavior — input device, hotkeys, meeting auto-record,
    /// and Daisy's on-screen presence (menu bar + floating widget).
    /// Split out of the overloaded General tab in 1.0.7.16.
    case recording
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
/// General. Notion briefly lived in Settings → General → Storage
/// (1.0.5) but came back to Connections in 1.0.7.16 — it's an
/// outbound send-to destination, so it renders as a "Notion" Section
/// at the top of the Auto-routing tab rather than getting its own
/// `ConnectionSection` case. Google Calendar OAuth UI is dormant
/// pre-verification; when it returns it'll come back as its own case
/// here.
enum ConnectionSection: String, Hashable, Sendable {
    case mcpServer
    case autoRouting
    // Google Calendar OAuth row moved to Settings → Permissions
    // → Calendar in build 42 (2026-05-28). Both calendar sources
    // (Apple via EventKit, Google via OAuth) now live side-by-side
    // in Permissions so users see "where Daisy reads calendar data
    // from" in one place. Connections is now strictly outbound
    // integrations (auto-routing + MCP server).
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
        // 2026-05-27 — remove SwiftUI's auto-generated sidebar toggle
        // from the toolbar. Apple bug on macOS 26.2: the toggle is
        // backed by `NSSegmentedCell`, and during layout / mouseDown
        // processing the bridge runs `swift_task_isCurrentExecutor`
        // → `swift_getObjectType` → `objc_msgSend` on a deallocated
        // class metadata pointer (use-after-free in the Swift
        // concurrency↔AppKit bridge). Reproduces on 1.0.7.3 / 26.2
        // (25C56) every time the user starts a recording (via
        // hotkey AND main-window button). Same UAF family as the
        // documented 26.0.1 SwiftUI Button crash, now in
        // SystemSegmentedControl. Hiding the toggle means SwiftUI
        // doesn't materialize the NSSegmentedCell, so the buggy
        // code path can't execute. Trade-off: user loses the
        // 1-click sidebar collapse from the toolbar; they can
        // still drag the divider, and Daisy's sidebar is
        // permanently informative (Home / Library / Connections /
        // Settings / About) so collapsing it wasn't a primary use
        // case anyway.
        .toolbar(removing: .sidebarToggle)
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
        // Reactive service re-wiring, lifted out of `body` into
        // ViewModifiers. Inline, this was 14 chained `.onChange`
        // handlers stacked on the toolbar/sheet/styling chain, which
        // tripped the Swift type-checker's complexity limit ("unable
        // to type-check this expression in reasonable time") once the
        // auto-start policy added five more. Each modifier below is its
        // own type-check scope. Initial wiring still runs in
        // DaisyApp.init via the same ServiceWiring helpers.
        .modifier(HotkeyStopWiring(settings: settings, session: session))
        .modifier(AutoStartWiring(settings: settings, session: session))
        .modifier(CalendarServerWiring(settings: settings, session: session))
        .modifier(CompactModeWiring(settings: settings))
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
                    // 2026-05-25 — capsule was visibly narrower than
                    // the Home / Library / etc. selection chips above.
                    // `List(.sidebar)` adds ~8pt implicit horizontal
                    // inset that we can't override directly. Negative
                    // listRowInsets cancel that inset so the capsule's
                    // outer edges land at the same x-coordinates as
                    // the highlight chip on the row above. Combined
                    // with the capsule's own 10pt internal text
                    // padding the visual width now matches.
                    .listRowInsets(EdgeInsets(top: 14, leading: -8, bottom: 4, trailing: -8))
                    .listRowBackground(Color.clear)

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
                        // 2026-05-25 — padding tracks RecordCapsule's
                        // pad recipe exactly so the two capsules
                        // render as a matched pair (same width, same
                        // height, same internal rhythm — Pause toggle
                        // on top, Stop & save underneath). Egor's
                        // pass bumped horizontal 8 → 12 to give the
                        // stop glyph + label room from the capsule
                        // curve. If RecordCapsule's h-pad ever moves,
                        // bump this one in lockstep.
                        .padding(.horizontal, 12)
                        .padding(.vertical, 14)
                        .foregroundStyle(Color.daisyTextPrimary)
                        .background(
                            Capsule(style: .continuous).fill(Color.daisyBgElevated)
                        )
                        .overlay(
                            Capsule(style: .continuous).strokeBorder(Color.daisyDivider, lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                    // Same negative-inset compensation as RecordCapsule
                    // above so the Stop button lines up with the
                    // capsule edges (and therefore with the sidebar
                    // row chips above) instead of sitting indented.
                    .listRowInsets(EdgeInsets(top: 0, leading: -8, bottom: 4, trailing: -8))
                    .listRowBackground(Color.clear)
                }

                // System-audio status row — UNDER the Stop button.
                // Order: tap-target first, status second. The status
                // is informational ("here's what's being captured");
                // putting it above Stop made the eye land on a label
                // before the actionable button, which felt wrong.
                if session.status == .recording || session.status == .paused {
                    SystemAudioStatusPill(session: session)
                        // 2026-05-25 — top inset 0 → 12 per Egor's
                        // pass. The status pill belongs to a
                        // different visual family than the Pause /
                        // Stop & save matched-pair above (capsules =
                        // primary actions; pill = informational
                        // status). Pre-bump the 4pt gap inherited
                        // from Pause→Stop made the three rows read
                        // as one undifferentiated stack. 12pt drops
                        // the pill far enough below the action pair
                        // to be parsed as "status note on the
                        // current recording" rather than "third
                        // button in a row".
                        .listRowInsets(EdgeInsets(top: 12, leading: -8, bottom: 8, trailing: -8))
                        .listRowBackground(Color.clear)
                }

                // One-time speech-model download progress. Unlike the
                // rows above this is NOT gated on recording state: the
                // big Whisper download (~626 MB) kicks off at first
                // launch, before the user ever hits Record, and used to
                // be visible only in the widget tooltip + Settings
                // badge. The pill renders nothing once engines are
                // ready, so in the common steady state this row simply
                // isn't there. Same negative-inset compensation as the
                // pills above; 12pt top gap = informational-row rhythm
                // (matches SystemAudioStatusPill's spacing rationale).
                ModelDownloadPill(settings: settings)
                    .listRowInsets(EdgeInsets(top: 12, leading: -8, bottom: 8, trailing: -8))
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
                    // 2026-05-27 — click-to-copy on the version pill.
                    // Useful for bug reports / support — user posts a
                    // GitHub issue or DM and pastes "Daisy 1.0.7.2 (29)"
                    // instead of squinting at the pill, then asking
                    // which one is the build. No visual change: same
                    // font/colour/padding. `.contentShape` widens the
                    // hit-target to the whole text frame (otherwise
                    // SwiftUI hit-tests glyph rectangles only, which
                    // makes single-digit versions tiny). `.help`
                    // surfaces the affordance on hover without adding
                    // an icon, per Egor's "no icon" constraint.
                    .contentShape(Rectangle())
                    .onTapGesture { VersionInfo.copyToClipboardWithToast() }
                    .help("Click to copy version")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    private var appVersion: String { VersionInfo.marketingVersion }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch nav.section {
        case .home:
            HomeView(session: session)
        case .library:
            LibraryView()
        case .dictation:
            DictationView()
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

/// Tiny status row under the Stop button during active recording.
/// Tells the user what's actually being captured right now, in
/// plain language — no "capture", "stream", "permission" jargon
/// that needs decoding mid-meeting.
///
///   • capturing → "Recording both sides" — green dot, sage tint
///   • denied    → "Only your voice — Screen Recording is off"
///                 (clickable: opens System Settings)
///   • failed    → "Only your voice — couldn't reach the other side"
///                 (full error in tooltip on hover)
///
/// `.disabled` and `.pending` render nothing — the user either
/// turned system audio off on purpose, or recording hasn't started.
struct SystemAudioStatusPill: View {
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

    /// Sage-tinted capsule confirming both sides are being captured.
    /// Matches the visual weight of the warning states below so the
    /// status row stays consistent regardless of state — eye lands
    /// on the same shape, only the colour and copy change.
    ///
    /// 2026-05-25 — opacity recipe synced to the unified banner
    /// family (0.20 fill + 0.20 strokeBorder). Pre-sync this used
    /// 0.10 / 0.25 (the "subtle status pill" recipe) but the
    /// warning siblings below were on the same recipe with no
    /// affordance distinction — eye couldn't pick out that the
    /// warning was clickable. Now all three states share the
    /// banner-family 0.20/0.20 chip, vertical pad bumped 6 → 10 to
    /// give the text room when it wraps to two lines.
    private var capturingPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.daisySuccess)
                .frame(width: 6, height: 6)
            Text("Recording both sides")
                .font(.caption)
                .foregroundStyle(Color.daisyTextPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            Capsule(style: .continuous).fill(Color.daisySuccess.opacity(0.20))
        )
        .overlay(
            Capsule(style: .continuous).strokeBorder(Color.daisySuccess.opacity(0.20), lineWidth: 0.5)
        )
    }

    /// Screen Recording permission denied — recording continues with
    /// mic only. The WHOLE pill is the tap target (opens System
    /// Settings → Privacy → Screen Recording); there is no separate
    /// "Fix" button. At the sidebar's ~200pt width the label plus a
    /// trailing CTA clipped to "Screen Recording is…", so the copy is
    /// now compact and the affordance is the pill itself (Egor,
    /// 2026-06-04). Cinnamon daisyAccent 0.20/0.20 chip; the warning
    /// reads from the glyph + the "click to fix" hint, full detail in
    /// the hover tooltip.
    private var deniedPill: some View {
        Button {
            ScreenRecordingPermission.openSystemSettings()
        } label: {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.daisyAccent)
                Text("Only your voice — click to fix")
                    .font(.caption)
                    .foregroundStyle(Color.daisyTextPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                Capsule(style: .continuous).fill(Color.daisyAccent.opacity(0.20))
            )
            .overlay(
                Capsule(style: .continuous).strokeBorder(Color.daisyAccent.opacity(0.20), lineWidth: 0.5)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Daisy needs Screen Recording permission to capture the other side of meetings. Click to open System Settings.")
    }

    /// System audio capture started but errored out mid-stream
    /// (display gone, ScreenCaptureKit threw, etc). The recording
    /// keeps going with mic only — full error in the help tooltip
    /// for the curious; the user-facing label stays simple.
    ///
    /// 2026-05-25 — same banner-family treatment as `deniedPill`.
    /// 2-line allowance + cinnamon 0.20/0.20 chip. No trailing CTA
    /// since there's nothing to click — the error is informational
    /// (the recording continues with mic only anyway).
    private func failedPill(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(Color.daisyAccent)
            Text("Only your voice — couldn't reach the other side")
                .font(.caption)
                .foregroundStyle(Color.daisyTextPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            Capsule(style: .continuous).fill(Color.daisyAccent.opacity(0.20))
        )
        .overlay(
            Capsule(style: .continuous).strokeBorder(Color.daisyAccent.opacity(0.20), lineWidth: 0.5)
        )
        .help(message)
    }
}

// MARK: - Model download pill

/// The single most relevant speech-model load in flight, unified across
/// the three ASR engines (whose `LoadState` enums are distinct types).
/// `ModelDownloadPill` (main-window sidebar) and the popover's progress
/// bar in `ContentView` both resolve through this, so the two surfaces
/// always describe the same download.
///
/// Priority when several engines load at once: Whisper > Parakeet >
/// Nemotron. Whisper is the engine every recording blocks on
/// (`RecordingSession.start()` awaits it); the other two are optional
/// dictation extras, so they only count while their settings toggles
/// are on — a disabled engine sits in `.notLoaded` forever and would
/// otherwise be permanent noise. One activity, never a stack.
enum ModelLoadActivity: Equatable {
    /// Engine reports `.downloading` but no bytes have moved yet —
    /// resolving the HF repo / checking the on-disk cache. Showing
    /// "Downloading… 0%" here is misleading (a cached model never
    /// downloads anything); surfaces render this as "Checking
    /// models…" with an indeterminate bar.
    case checking
    case downloading(progress: Double)
    case loading

    /// True while real bytes are moving — the only phase with a
    /// meaningful fraction.
    private static func classify(_ progress: Double) -> ModelLoadActivity {
        progress > 0.001 ? .downloading(progress: progress) : .checking
    }

    /// Highest-priority in-flight load, or `nil` when every relevant
    /// engine is `.notLoaded` / `.ready` / `.failed`. Failures stay
    /// out on purpose — they already surface via the Settings badge
    /// and the session status label, and a permanent red pill in the
    /// sidebar would shout forever with no action attached.
    ///
    /// Reading the engines' `@Observable` state inside a view body is
    /// what makes SwiftUI re-render as the download progresses — no
    /// timers, no polling.
    static func current(settings: AppSettings) -> ModelLoadActivity? {
        switch WhisperEngine.shared.state {
        case .downloading(let progress): return classify(progress)
        case .loading: return .loading
        case .notLoaded, .ready, .failed: break
        }
        if settings.dictationUseParakeet {
            switch ParakeetEngine.shared.state {
            case .downloading(let progress): return classify(progress)
            case .loading: return .loading
            case .notLoaded, .ready, .failed: break
            }
        }
        if settings.dictationUseNemotronLive {
            switch NemotronLiveEngine.shared.state {
            case .downloading(let progress): return classify(progress)
            case .loading: return .loading
            case .notLoaded, .ready, .failed: break
            }
        }
        return nil
    }
}

/// Sidebar progress row for the one-time speech-model download
/// (Whisper is ~626 MB on a fresh install; Parakeet / Nemotron when
/// those dictation engines are enabled). Until 1.0.7.19 the only
/// surfaces were the widget tooltip and the Settings → Transcription
/// badge — on a fresh install the main window gave no hint that a
/// large download was running (user feedback). Same banner-family
/// chip as `SystemAudioStatusPill` above (0.20 fill + 0.20
/// strokeBorder) with a thin linear bar inside.
///
///   • `.checking`    → "Checking models…" + indeterminate bar
///   • `.downloading` → "Downloading model… 67%" + determinate bar
///   • `.loading`     → "Loading model…" + indeterminate bar
///   • ready / failed / not loaded → renders nothing (steady state;
///     failures keep their existing Settings-badge + status-label paths)
struct ModelDownloadPill: View {
    /// Plain `let` is enough — Observation tracks the `settings.*`
    /// and `*Engine.shared.state` reads inside `body` (made via
    /// `ModelLoadActivity.current`) without `@Bindable`.
    let settings: AppSettings

    var body: some View {
        switch ModelLoadActivity.current(settings: settings) {
        case .checking?:
            // Eyes, not a download arrow — nothing is downloading yet,
            // Daisy is just looking around (cache check / repo resolve).
            pill(label: "Checking models…", icon: "eyes", progress: nil)
        case .downloading(let progress)?:
            pill(
                label: "Downloading model… \(Int(progress * 100))%",
                icon: "arrow.down.circle",
                progress: min(max(progress, 0), 1)
            )
        case .loading?:
            pill(label: "Loading model…", icon: "arrow.down.circle", progress: nil)
        case nil:
            EmptyView()
        }
    }

    /// Banner-family chip — cinnamon accent (informational, not a
    /// warning, so no exclamation glyph), icon + caption on top, thin
    /// bar underneath. `progress == nil` renders the indeterminate
    /// linear bar for the brief CoreML-init phase, where no meaningful
    /// fraction exists.
    private func pill(label: String, icon: String, progress: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(Color.daisyAccent)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(Color.daisyTextPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            ProgressView(value: progress, total: 1.0)
                .progressViewStyle(.linear)
                .controlSize(.small)
                .tint(Color.daisyAccent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        // Rounded rectangle, NOT the banner capsule — with two stacked
        // lines + a progress bar inside, a capsule's fully-round ends
        // swallow the corners (user feedback on first build).
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.daisyAccent.opacity(0.20))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.daisyAccent.opacity(0.20), lineWidth: 0.5)
        )
        .help("One-time setup: Daisy transcribes on-device, so the model has to download first. Recording starts as soon as it's ready.")
    }
}


// MARK: - Service re-wiring modifiers
//
// The reactive ServiceWiring re-application that used to live as a long
// `.onChange` chain on `MainView.body`, split across three ViewModifiers
// purely to stay within the Swift type-checker's expression-complexity
// budget. Behaviour is identical to the former inline chain; only the
// grouping is new. Plain `let` (not @Bindable) is enough — Observation
// tracks the `settings.*` reads inside each `.onChange(of:)`.

private struct HotkeyStopWiring: ViewModifier {
    let settings: AppSettings
    let session: RecordingSession

    func body(content: Content) -> some View {
        content
            .onChange(of: settings.recordHotkey) { _, _ in
                ServiceWiring.applyAllHotkeys(settings: settings, session: session)
            }
            .onChange(of: settings.voiceNoteHotkey) { _, _ in
                ServiceWiring.applyAllHotkeys(settings: settings, session: session)
            }
            .onChange(of: settings.dictationHotkey) { _, _ in
                ServiceWiring.applyAllHotkeys(settings: settings, session: session)
            }
            // Granola-style auto-open: jump to History on the freshly
            // finished session when the user opted in.
            .onChange(of: session.status) { _, new in
                if case .finished = new,
                   settings.showSessionAfterStop,
                   let id = session.sessionDirectory?.lastPathComponent {
                    AppNavigation.shared.openInLibrary(id)
                }
            }
    }
}

private struct AutoStartWiring: ViewModifier {
    let settings: AppSettings
    let session: RecordingSession

    func body(content: Content) -> some View {
        content
            .onChange(of: settings.autoStartPolicy) { _, _ in
                ServiceWiring.applyMeetingAutoStart(settings: settings, session: session)
                ServiceWiring.applyCalendar(settings: settings, session: session)
            }
            .onChange(of: settings.autoStartOnMeeting) { _, _ in
                ServiceWiring.applyMeetingAutoStart(settings: settings, session: session)
            }
            .onChange(of: settings.autoStartPromptMode) { _, _ in
                ServiceWiring.applyMeetingAutoStart(settings: settings, session: session)
            }
            .onChange(of: settings.autoStartFromCalendar) { _, _ in
                ServiceWiring.applyCalendar(settings: settings, session: session)
            }
    }
}

private struct CalendarServerWiring: ViewModifier {
    let settings: AppSettings
    let session: RecordingSession

    func body(content: Content) -> some View {
        content
            .onChange(of: CalendarService.shared.authorizationStatus) { _, status in
                let granted = (status == .fullAccess)
                if settings.calendarAccessGranted != granted {
                    settings.calendarAccessGranted = granted
                }
                ServiceWiring.applyCalendar(settings: settings, session: session)
            }
            .onChange(of: GoogleAccountStore.shared.isConnected) { _, _ in
                ServiceWiring.applyCalendar(settings: settings, session: session)
            }
            .onChange(of: settings.mcpServerEnabled) { _, _ in
                ServiceWiring.applyMCPServer(settings: settings)
            }
            .onChange(of: settings.mcpServerPort) { _, _ in
                if settings.mcpServerEnabled {
                    ServiceWiring.applyMCPServer(settings: settings)
                }
            }
    }
}

/// Live application of the compact / menu-bar-only toggle (Settings →
/// Recording). The launch-time decision lives in
/// `DaisyAppDelegate.applicationDidFinishLaunching`; this modifier makes
/// runtime flips take effect WITHOUT a relaunch.
///
///   • ON  → switch to `.accessory` (drop the Dock icon / Cmd+Tab) and
///           close the main window. The menu-bar popover + floating
///           widget remain; the popover's "More" menu still offers
///           "Open Library…" / "Settings…" and "Quit Daisy", so the user
///           can always get the window back or quit.
///   • OFF → switch to `.regular` (Dock icon returns) and re-open + raise
///           the main window, restoring today's default experience.
///
/// `openWindow(id:"main")` is the same entry point the menu-bar popover
/// uses, so re-opening here is guaranteed to focus the single `Window`
/// scene rather than spawn a duplicate. Plain `let` is enough —
/// Observation tracks the `settings.compactMenuBarOnly` read inside the
/// `.onChange`.
private struct CompactModeWiring: ViewModifier {
    let settings: AppSettings
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
            .onChange(of: settings.compactMenuBarOnly) { _, isCompact in
                if isCompact {
                    NSApp.setActivationPolicy(.accessory)
                    // Drop the Dock icon and tuck the window away. Closing
                    // (not destroying) keeps the `Window` scene reopenable.
                    for window in NSApp.windows where window.canBecomeMain {
                        window.close()
                    }
                } else {
                    NSApp.setActivationPolicy(.regular)
                    // Bring Daisy fully back: Dock icon + the main window,
                    // focused. `openWindow` re-presents the single `Window`
                    // scene; `activate` pulls the app to the foreground so
                    // the restored window isn't buried behind other apps.
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
    }
}
