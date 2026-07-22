//
//  HomeView.swift
//  Daisy
//
//  Primary "landing" view that opens when the user clicks the Dock
//  icon. A calm hub: a serif greeting, today's agenda (DayCard), usage
//  stats, and the last few recordings. Recording itself is driven by the
//  persistent RecordCapsule / hotkey, not a button here.
//

import AppKit
import EventKit
import SwiftUI

struct HomeView: View {
    @Bindable var session: RecordingSession
    @Bindable var store = SessionStore.shared
    @Bindable var usage = UsageStats.shared
    @Bindable var nav = AppNavigation.shared
    @Bindable var calendar = CalendarService.shared
    /// Observe Google OAuth state so the upcoming-events section
    /// re-renders when the user connects/disconnects Google in
    /// Settings. Without this binding the switch below stays
    /// on the Apple-Calendar-only path and visibly hides events
    /// even though `calendar.upcomingEvents` was just populated
    /// by the Google fetch.
    @Bindable var folders = FolderStore.shared
    @Bindable var integrationStore = MCPIntegrationStore.shared
    @Bindable private var permissions = SystemPermissions.shared
    /// Read-through to the session's settings — the destinations
    /// hint uses `hasNotionCredentials`. Done as a computed
    /// passthrough rather than a separate @Bindable property so
    /// we don't accept two settings sources of truth.
    private var settings: AppSettings { session.settings }

    /// Persisted "Don't show again" for the onboarding checklist — set from
    /// the dismiss button, which only appears once the required permissions
    /// are granted. Hides the block for good on Home.
    @AppStorage("daisy.onboardingDismissed") private var onboardingDismissed = false


    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                welcomeHeader
                // Permissions moved from a full-width top banner into the
                // onboarding checklist that sits above the day card in the
                // right column (2026-07-21) — a calmer "finish setting up"
                // block instead of an alarm bar.
                homeColumns
                if showDestinationsHint { destinationsHint }
            }
            .padding(.top, 24)
            .padding(.bottom, 32)
            // Cap the content column and centre it, instead of stretching
            // edge-to-edge on wide windows. Was 720 to match the grouped-Form
            // pages; widened to 1040 so the stats row (words/min · total
            // words · activity heatmap) fits on ONE line with the 26-week
            // heatmap taking half the width (Egor, 2026-07-14).
            .frame(maxWidth: 1040, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .task {
            await store.refresh()
            // Rebuild the open-items list now that the session corpus is
            // loaded. MorningBriefStore.prepare also rebuilds, but the day
            // card's own `.task` can fire before this refresh finishes on a
            // cold launch — leaving the to-do list empty even though the
            // (cached) lede already names the tasks. Redo it here so the
            // checkable items always appear once sessions are in.
            ActionItemStore.shared.rebuild(from: store.sessions)
            // One-time: seed the usage widgets from the existing Library
            // so long-time users don't see an empty stats block.
            usage.backfillIfNeeded(from: store.sessions)
            // Keep the daily morning-brief notification armed (idempotent).
            MorningBriefStore.rescheduleNotification(settings: settings)
        }
        .tint(Color.daisyHomeAccent)
    }

    // MARK: - Welcome header

    /// Serif greeting at the very top of Home. Uses Apple's system serif
    /// (New York) via `.serif` fontDesign. Appends the user's display
    /// name when set ("Welcome back, Egor"); bare "Welcome back" otherwise.
    private var welcomeHeader: some View {
        let name = settings.userDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let greeting = name.isEmpty
            ? String(localized: "Welcome back")
            : String(localized: "Welcome back, \(name)")
        return Text(greeting)
            .font(.system(.largeTitle, design: .serif).weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 24)
    }

    // MARK: - Onboarding checklist
    //
    // Replaces the old full-width permissions alarm bar (2026-07-21).
    // A calm "finish setting up Daisy" checklist that lives above the
    // day card in the right column and disappears once everything is
    // handled. Required rows (Microphone, Accessibility) always show
    // until granted; optional rows (Screen Recording, Calendar) show
    // only while still undecided (notDetermined) — once the user has
    // acted on them, we stop nudging.

    /// Show the checklist while any required permission is missing OR an
    /// optional one hasn't been decided yet. Hidden entirely when setup
    /// is complete so Home is clean for the everyday case.
    private var shouldShowOnboarding: Bool {
        guard !onboardingDismissed else { return false }
        return permissions.microphone != .granted
            || permissions.accessibility != .granted
            || permissions.screenRecording == .notDetermined
            || permissions.calendar == .notDetermined
    }

    /// Both REQUIRED permissions granted — the point at which we let the
    /// user dismiss the whole checklist (optional rows may still linger,
    /// but nothing is broken, so "Don't show again" is safe to offer).
    private var requiredPermissionsMet: Bool {
        permissions.microphone == .granted && permissions.accessibility == .granted
    }

    private var onboardingChecklist: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Finish setting up Daisy")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                // Low-emphasis escape hatch — only once the essentials are
                // in place, so the user can't skip past a broken setup.
                if requiredPermissionsMet {
                    Button(String(localized: "Don't show again")) {
                        onboardingDismissed = true
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            onboardingRow(
                title: String(localized: "Microphone"),
                caption: String(localized: "Captures your voice"),
                status: permissions.microphone,
                action: { Task { await permissions.requestMicrophone() } },
                openSettings: permissions.openMicrophoneSettings
            )
            onboardingRow(
                title: String(localized: "Accessibility"),
                caption: String(localized: "Lets dictation paste into any app"),
                status: permissions.accessibility,
                action: { permissions.requestAccessibility() },
                openSettings: permissions.openAccessibilitySettings
            )
            onboardingRow(
                title: String(localized: "Screen Recording"),
                caption: String(localized: "Captures the other side of meetings"),
                status: permissions.screenRecording,
                action: { permissions.requestScreenRecording() },
                openSettings: permissions.openScreenRecordingSettings
            )
            onboardingRow(
                title: String(localized: "Calendar"),
                caption: String(localized: "Auto-starts recording at meeting times"),
                status: permissions.calendar,
                action: { Task { await permissions.requestCalendar() } },
                openSettings: permissions.openCalendarSettings
            )
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.daisyBgElevated, in: RoundedRectangle(cornerRadius: 10))
    }

    /// One checklist line: a status glyph (filled check when granted) plus
    /// the name + one-line rationale. The WHOLE row is the tap target —
    /// notDetermined requests the permission, denied/restricted opens
    /// System Settings, granted is inert. No buttons (keeps the block
    /// calm); a hover highlight + trailing chevron signal it's clickable.
    @ViewBuilder
    private func onboardingRow(
        title: String,
        caption: String,
        status: SystemPermissions.Status,
        action: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) -> some View {
        let granted = (status == .granted)
        Button {
            switch status {
            case .granted:       break
            case .notDetermined: action()
            // denied / restricted / insufficient — the system won't prompt
            // again, so send them to System Settings.
            default:             openSettings()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(granted ? Color.daisyHomeAccent : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.callout.weight(.medium))
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(granted)
        .modifier(OnboardingRowHover(active: !granted))
    }

    // MARK: - Destinations discoverability

    /// Show the destination-setup nudge when:
    ///   • At least one session exists (proves user is past the
    ///     "haven't recorded yet" stage and might want a destination)
    ///   • AND nothing is configured: no Notion creds, no MCP
    ///     integrations enabled.
    /// Without this, Send-to integrations stay invisible — the
    /// feature lives behind Settings, and users we surveyed didn't
    /// know it existed.
    private var showDestinationsHint: Bool {
        guard !store.sessions.isEmpty else { return false }
        let hasNotion = settings.hasNotionCredentials
        let hasMCP = !integrationStore.enabledIntegrations.isEmpty
        return !hasNotion && !hasMCP
    }

    private var destinationsHint: some View {
        HStack(spacing: 10) {
            Image(systemName: "paperplane.circle.fill")
                .font(.title3)
                .foregroundStyle(Color.daisyHomeAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Send recordings somewhere")
                    .font(.callout.weight(.medium))
                Text("Daisy can push finished recordings to Notion, Linear, Slack, or any MCP server — automatically or via the kebab menu in History.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button {
                // Deep-link straight to Connections → Auto-routing —
                // landing on generic Settings left users hunting for
                // where destinations actually live.
                AppNavigation.shared.pendingConnectionsSection = .autoRouting
                AppNavigation.shared.section = .connections
            } label: {
                Text("Set up").frame(minWidth: 120)
                    .foregroundStyle(Color.daisyBannerActionText)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.daisyBannerAction)
            .controlSize(.regular)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.daisyBannerBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.daisyBannerBorder, lineWidth: 1)
        )
        .padding(.horizontal, 24)
    }

    // MARK: - Two-column band: calendar ↔ recent recordings

    /// Calendar events (left) and recent recordings (right), half the
    /// content width each (Egor, 2026-07-14). When no calendar source is
    /// connected the recordings take the full width — an empty left
    /// column would just be dead space.
    /// One gutter for every column split on Home (stats row + the
    /// calendar/recordings band) so vertical boundaries align.
    static let columnGap: CGFloat = 16

    /// Home body layout (2026-07-21, per Egor's mock): two full-height
    /// columns. LEFT = activity heatmap, then the fixes/words number pair,
    /// then recent recordings. RIGHT = the DayCard (morning lede + agenda
    /// + open items).
    ///
    /// The layout is FIXED regardless of calendar state (Egor 2026-07-22):
    /// no calendar just means the day card shows less inside it — it must
    /// NOT restack the whole screen into one column. The old single-column
    /// fallback made a fresh install (or a permissions-reset release build)
    /// look like a different app.
    private var homeColumns: some View {
        HStack(alignment: .top, spacing: Self.columnGap) {
            leftColumn
                .frame(maxWidth: .infinity, alignment: .topLeading)
            dayColumn
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 24)
    }

    /// Right column: the onboarding checklist (while setup is unfinished)
    /// stacked above the day card.
    @ViewBuilder
    private var dayColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            if shouldShowOnboarding {
                onboardingChecklist
            }
            dayCard
        }
    }

    /// Left column stack: heatmap on top, the fixes/words number pair
    /// beneath it, then recent recordings. Stats hide until there's at
    /// least one session so a fresh install isn't greeted by zeros.
    @ViewBuilder
    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            if usage.totalCount > 0 {
                heatmapCard
                HStack(alignment: .top, spacing: Self.columnGap) {
                    fixesCard
                    wordsCard
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            recentSessionsSection
        }
    }

    /// The unified "your day" card — lede + agenda (with inline Prep +
    /// per-meeting tasks) + standalone open items. Replaces the old
    /// morning-brief card, Today/Tomorrow column, and standalone brief card.
    private var dayCard: some View {
        DayCard(
            events: displayedEvents,
            isTomorrow: showingTomorrow,
            settings: settings,
            onStartMeeting: { event in
                Task { await session.startFromMeeting(event) }
            }
        )
    }

    // MARK: - Calendar plumbing (consumed by DayCard)

    // (`hasAnyCalendarSource` removed 2026-07-22 — the column layout no
    // longer branches on calendar state; DayCard degrades internally.)

    /// All remaining events for today — calendar-day filter, not 24h
    /// rolling window. If it's 23:00 and an event is tomorrow at
    /// 01:00, we don't want to show it under "today".
    private var todaysEvents: [DaisyMeeting] {
        let cal = Calendar.current
        let now = Date()
        return calendar.upcomingEvents.filter { event in
            // Still relevant — either upcoming today, or currently in
            // progress (started already but not ended yet).
            cal.isDate(event.startDate, inSameDayAs: now) && event.endDate > now
        }
    }

    /// Tomorrow's events (whole calendar day). Needs the 48h calendar
    /// lookahead (see ServiceWiring) so the full day is loaded.
    private var tomorrowsEvents: [DaisyMeeting] {
        let cal = Calendar.current
        guard let tomorrow = cal.date(byAdding: .day, value: 1, to: Date()) else { return [] }
        return calendar.upcomingEvents.filter { cal.isDate($0.startDate, inSameDayAs: tomorrow) }
    }

    /// Once today's meetings are all done, roll the section over to show
    /// tomorrow instead of an empty "today".
    private var showingTomorrow: Bool {
        todaysEvents.isEmpty && !tomorrowsEvents.isEmpty
    }

    /// The events actually rendered — today's if any remain, else
    /// tomorrow's. Empty only when there's nothing in either day.
    private var displayedEvents: [DaisyMeeting] {
        showingTomorrow ? tomorrowsEvents : todaysEvents
    }

    // (sectionHeader / eventsBody / UpcomingEventRow removed 2026-07-15 —
    // the DayCard renders the agenda now, with inline Prep + nested tasks.)

    // (connectCalendarCTA / deniedCalendarCTA removed 2026-07-21 — the
    // onboarding checklist's Calendar row is the only calendar nudge on
    // Home now; the standalone banners were dead code.)

    // MARK: - Usage stats (words/min · total words · activity)

    /// Wispr-style "fixes" card: big total + breakdown (dictionary
    /// replacements / voice-polish changes). Counters start at zero on
    /// this build — they can't be backfilled.
    private var fixesCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(usage.totalFixes.formatted(.number))
                .font(.title.weight(.semibold))
                .foregroundStyle(.primary)
            Text("Fixes made by Daisy")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Rectangle()
                .fill(Color.daisyDivider.opacity(0.5))
                .frame(height: 1)
                .padding(.horizontal, -16)
                .padding(.vertical, 4)
            HStack(spacing: 6) {
                Text(usage.totalDictionaryFixes.formatted(.number))
                Text("Dictionary")
                Spacer()
            }
            .daisyStatLabel()
            HStack(spacing: 6) {
                Text(usage.totalPolishedWords.formatted(.number))
                Text("Voice polish")
                Spacer()
            }
            .daisyStatLabel()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
        .background(Color.daisyBgElevated, in: RoundedRectangle(cornerRadius: 10))
    }

    /// Combined words card: total words big, dictation words/min beneath.
    private var wordsCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(usage.totalWords.formatted(.number))
                .font(.title.weight(.semibold))
                .foregroundStyle(.primary)
            Text("Total words")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Rectangle()
                .fill(Color.daisyDivider.opacity(0.5))
                .frame(height: 1)
                .padding(.horizontal, -16)
                .padding(.vertical, 4)
            HStack(spacing: 6) {
                // "—" until the first dictation lands: WPM is dictation-
                // only, and a literal 0 reads as broken.
                Text(usage.averageWPM > 0 ? "\(usage.averageWPM)" : "—")
                Text("Words / min")
                Spacer()
            }
            .daisyStatLabel()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
        .background(Color.daisyBgElevated, in: RoundedRectangle(cornerRadius: 10))
    }

    private var heatmapCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Activity")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Text(usage.currentStreak == 1
                     ? String(localized: "1 day streak")
                     : String(localized: "\(usage.currentStreak) day streak"))
                    .daisyStatLabel()
            }
            MeetingsHeatmap(dayCounts: usage.dayCounts())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.daisyBgElevated, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Recent sessions

    private var recentSessionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent recordings")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Button("Open Library") {
                    nav.section = .library
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if store.sessions.isEmpty {
                ContentUnavailableView(
                    "No recordings yet",
                    systemImage: "tray",
                    description: Text("Click Record to make your first one.")
                )
                .frame(maxWidth: .infinity)
                .frame(height: 160)
            } else {
                // One block, no dividers — the per-row hover carries the
                // separation now.
                VStack(spacing: 0) {
                    ForEach(Array(store.sessions.prefix(5))) { session in
                        RecentSessionRow(session: session) {
                            // Deep-link into the Library view with this
                            // session pre-selected, not the default row.
                            nav.openInLibrary(session.id)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.daisyBgElevated, in: RoundedRectangle(cornerRadius: 10))
    }


}

// MARK: - Recent session row

/// Shared minimum content height for the Home list rows (see DayCard's
/// agenda rows for the calendar side).
private let homeRowMinHeight: CGFloat = 36

/// Subtle hover highlight for the onboarding checklist rows. `active` is
/// false for a granted (inert) row, so it never lights up. Pads a comfy
/// hit area, draws a faint fill on hover, then negates the padding so the
/// row layout doesn't shift.
private struct OnboardingRowHover: ViewModifier {
    let active: Bool
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(active && hovering ? 0.06 : 0))
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .padding(.horizontal, -8)
            .padding(.vertical, -6)
            .animation(.easeInOut(duration: 0.12), value: hovering)
    }
}

extension View {
    /// Shared secondary "stat label" style — the same aligned look as the
    /// uppercase section headers on Home (caption · semibold · secondary ·
    /// uppercase). Used for the number-led breakdown rows in the stat
    /// cards, the streak, the heatmap session count, and the day-card
    /// counts, so every small figure+label reads the same.
    func daisyStatLabel() -> some View {
        self.font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}

private struct RecentSessionRow: View {
    let session: StoredSession
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(formattedDate)
                        Text("·")
                        Text(formattedDuration)
                        if session.hasSummary {
                            Text("·")
                            Image(systemName: "sparkles")
                                .foregroundStyle(Color.daisyHomeAccent)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .frame(minHeight: homeRowMinHeight)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(hovering ? 0.06 : 0))
                    // Extend 8pt past the content on each side so the
                    // highlight lines up with the day-card / onboarding rows.
                    .padding(.horizontal, -8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovering)
    }

    // One shared formatter instead of allocating per row per render.
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private var formattedDate: String {
        Self.dateFormatter.string(from: session.startedAt)
    }

    private var formattedDuration: String {
        let total = max(0, session.durationSec)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
