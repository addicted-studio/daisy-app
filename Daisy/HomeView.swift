//
//  HomeView.swift
//  Daisy
//
//  Primary "landing" window that opens when the user clicks the Dock
//  icon. Dispatcher hub: big Start/Stop button, current status, last
//  few sessions, and shortcuts into the History + Settings windows.
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
    @Bindable private var google = GoogleAccountStore.shared
    @Bindable var folders = FolderStore.shared
    @Bindable var integrationStore = MCPIntegrationStore.shared
    @Bindable private var permissions = SystemPermissions.shared
    /// Read-through to the session's settings — the destinations
    /// hint uses `hasNotionCredentials`. Done as a computed
    /// passthrough rather than a separate @Bindable property so
    /// we don't accept two settings sources of truth.
    private var settings: AppSettings { session.settings }


    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Permissions moved from a full-width top banner into the
                // onboarding checklist that sits above the day card in the
                // right column (2026-07-21) — a calmer "finish setting up"
                // block instead of an alarm bar.
                homeColumns
                if showDestinationsHint { destinationsHint }
                Spacer(minLength: 0)
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
            // One-time: seed the usage widgets from the existing Library
            // so long-time users don't see an empty stats block.
            usage.backfillIfNeeded(from: store.sessions)
            // Keep the daily morning-brief notification armed (idempotent).
            MorningBriefStore.rescheduleNotification(settings: settings)
        }
        .tint(Color.daisyHomeAccent)
    }

    // MARK: - Permissions banner
    //
    // Sticky at the top of Home if either Microphone or Accessibility
    // is missing — those two are required, recording / dictation will
    // fail silently without them. Calendar / Screen Recording are
    // optional and don't trigger this banner.

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
        permissions.microphone != .granted
            || permissions.accessibility != .granted
            || permissions.screenRecording == .notDetermined
            || permissions.calendar == .notDetermined
    }

    private var onboardingChecklist: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Finish setting up Daisy")
                .font(.callout.weight(.semibold))

            onboardingRow(
                title: String(localized: "Microphone"),
                caption: String(localized: "Required — captures your voice"),
                status: permissions.microphone,
                action: { Task { await permissions.requestMicrophone() } },
                openSettings: permissions.openMicrophoneSettings
            )
            onboardingRow(
                title: String(localized: "Accessibility"),
                caption: String(localized: "Required — lets dictation paste into any app"),
                status: permissions.accessibility,
                action: { permissions.requestAccessibility() },
                openSettings: permissions.openAccessibilitySettings
            )
            onboardingRow(
                title: String(localized: "Screen Recording"),
                caption: String(localized: "Optional — captures the other side of meetings"),
                status: permissions.screenRecording,
                action: { permissions.requestScreenRecording() },
                openSettings: permissions.openScreenRecordingSettings
            )
            onboardingRow(
                title: String(localized: "Calendar"),
                caption: String(localized: "Optional — auto-starts recording at meeting times"),
                status: permissions.calendar,
                action: { Task { await permissions.requestCalendar() } },
                openSettings: permissions.openCalendarSettings
            )
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.daisyBgElevated, in: RoundedRectangle(cornerRadius: 10))
    }

    /// One checklist line: a status glyph (filled check when granted),
    /// the name + one-line rationale, and a trailing action — "Allow"
    /// when the system can still prompt, "Open Settings" once denied.
    @ViewBuilder
    private func onboardingRow(
        title: String,
        caption: String,
        status: SystemPermissions.Status,
        action: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) -> some View {
        let granted = (status == .granted)
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(granted ? Color.daisySuccess : Color.daisyTextTertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !granted {
                switch status {
                case .notDetermined:
                    Button(String(localized: "Allow")) { action() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(Color.daisyBannerAction)
                        .foregroundStyle(Color.daisyBannerActionText)
                default:
                    // denied / restricted / insufficient — the system
                    // won't prompt again, so send them to Settings.
                    Button(String(localized: "Open Settings")) { openSettings() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
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
    /// + open items). Previously the stats sat in their own top band with
    /// [numbers | heatmap] and the columns below were [dayCard | recent];
    /// this pulls the heatmap up-left and moves the day card to the right.
    @ViewBuilder
    private var homeColumns: some View {
        if hasAnyCalendarSource {
            HStack(alignment: .top, spacing: Self.columnGap) {
                leftColumn
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                dayColumn
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(.horizontal, 24)
        } else {
            // No calendar connected: the day card still carries the lede +
            // open items (if any), stacked above the left-column content.
            VStack(alignment: .leading, spacing: 16) {
                dayColumn
                leftColumn
            }
            .padding(.horizontal, 24)
        }
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
        .padding(.vertical, 16)
    }

    // MARK: - Calendar plumbing (consumed by DayCard)

    /// True when at least one calendar source can deliver events
    /// — drives the source-agnostic gate above and the event-count
    /// pill in the section header. Reads `SystemPermissions.calendar`
    /// (the same observable PermissionsView and SettingsView's
    /// Calendar section read) so all three surfaces agree on a
    /// single live source-of-truth. Pre-1.0.4 HomeView used
    /// `calendar.authorizationStatus`, which could drift from
    /// SystemPermissions across the auto-refresh window.
    private var hasAnyCalendarSource: Bool {
        permissions.calendar == .granted || google.isConnected
    }

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

    private var connectCalendarCTA: some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar.badge.plus")
                .font(.title3)
                .foregroundStyle(Color.daisyHomeAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text("See your meetings here")
                    .font(.callout.weight(.medium))
                Text("Connect Calendar to surface today's events and auto-start recordings when they begin")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            // minWidth lives on the LABEL inside the Button (not the
            // Button) so the bordered-prominent capsule sizes around the
            // wider text frame rather than hugging the label.
            Button {
                Task { _ = await calendar.requestAccess() }
                // MainView observes CalendarService.authorizationStatus
                // and wires AppSettings + service start on its own.
            } label: {
                Text("Connect").frame(minWidth: 120)
                    .foregroundStyle(Color.daisyBannerActionText)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .tint(Color.daisyBannerAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.daisyBannerBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.daisyBannerBorder, lineWidth: 1)
        )
    }

    private var deniedCalendarCTA: some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.title3)
                .foregroundStyle(Color.daisyHomeAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Calendar access is off")
                    .font(.callout.weight(.medium))
                Text("Grant access in System Settings → Privacy → Calendars to see upcoming meetings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button {
                calendar.openCalendarPrivacy()
            } label: {
                Text("Open Settings").frame(minWidth: 120)
                    .foregroundStyle(Color.daisyBannerActionText)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .tint(Color.daisyBannerAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.daisyBannerBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.daisyBannerBorder, lineWidth: 1)
        )
    }

    // MARK: - Usage stats (words/min · total words · activity)

    /// Wispr-style "fixes" card: big total + breakdown (dictionary
    /// replacements / voice-polish changes). Counters start at zero on
    /// this build — they can't be backfilled.
    private var fixesCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(usage.totalFixes.formatted(.number))
                .font(.system(size: 30, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
            Text("Fixes made by Daisy")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Divider().padding(.vertical, 4)
            HStack {
                Text("Dictionary")
                Spacer()
                Text(usage.totalDictionaryFixes.formatted(.number)).monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack {
                Text("Voice polish")
                Spacer()
                Text(usage.totalPolishedWords.formatted(.number)).monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
        .background(Color.daisyBgElevated, in: RoundedRectangle(cornerRadius: 10))
    }

    /// Combined words card: total words big, dictation words/min beneath.
    private var wordsCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(usage.totalWords.formatted(.number))
                .font(.system(size: 30, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
            Text("Total words")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Divider().padding(.vertical, 4)
            HStack {
                Text("Words / min")
                Spacer()
                // "—" until the first dictation lands: WPM is dictation-
                // only, and a literal 0 reads as broken.
                Text(usage.averageWPM > 0 ? "\(usage.averageWPM)" : "—").monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
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
                    .font(.caption)
                    .foregroundStyle(.tertiary)
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
                .buttonStyle(.borderless)
                .font(.caption)
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
                // spacing 6 = same rhythm as the events list next door.
                VStack(spacing: 6) {
                    ForEach(Array(store.sessions.prefix(5))) { session in
                        RecentSessionRow(session: session) {
                            // Deep-link into the Library view with
                            // this session pre-selected, instead of
                            // dumping the user on the default row.
                            nav.openInLibrary(session.id)
                        }
                    }
                }
            }
        }
        // Horizontal inset comes from `homeColumns` (the left column's
        // parent), so this section adds only vertical padding.
        .padding(.vertical, 16)
    }

}

// MARK: - Recent session row

/// Shared minimum content height for the Home list rows (see DayCard's
/// agenda rows for the calendar side).
private let homeRowMinHeight: CGFloat = 36

private struct RecentSessionRow: View {
    let session: StoredSession
    let onTap: () -> Void

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
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(Color.daisyBgElevated, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private var formattedDate: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: session.startedAt)
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
