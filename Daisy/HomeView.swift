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
                // 2026-05-25 — permissions banner is the only top-level
                // child rendered without going through a section wrapper,
                // so it needs its own horizontal inset to match the
                // calendar banner inside `upcomingSection` (which carries
                // `.padding(.horizontal, 24)`). Pre-fix it went edge-to-
                // edge and read as "different banner family" next to the
                // calendar one directly below.
                if permissions.needsAttention {
                    permissionsAttentionBanner
                        .padding(.horizontal, 24)
                }
                statsSection
                mainColumns
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

    private var permissionsAttentionBanner: some View {
        // 2026-05-25 — synced layout to match `connectCalendarCTA`
        // visually. Pre-fix this banner was visibly narrower than the
        // Connect Calendar banner directly below it, because of an
        // outer `.padding(.horizontal)` that wasn't there on the
        // calendar one. Also switched `.stroke` → `.strokeBorder` so
        // the 0.5pt border draws inside the rounded-rect edge (matches
        // calendar). Now the two banners read as one design family
        // separated by intent: orange warning chrome for required
        // missing perms, cinnamon info chrome for optional connect-up.
        HStack(spacing: 10) {
            // 2026-05-25 — icon switched `Color.daisyWarning` (orange)
            // → `Color.daisyAccent` (cinnamon) to harmonize with the
            // cinnamon chip background. Orange triangle on cinnamon
            // chip read as "two colours that almost match but don't",
            // i.e. clashing. The warning semantic is carried by the
            // glyph itself (`exclamationmark.triangle.fill`) and the
            // title text — colour is decoration, not the carrier.
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(Color.daisyHomeAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text(missingPermissionsTitle)
                    .font(.callout.weight(.medium))
                Text("Open Settings → Permissions to grant access")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            // 2026-05-25 — minWidth lives on the LABEL inside the
            // Button, not on the Button itself. `.frame(minWidth:)`
            // applied to the Button only reserves layout space — the
            // `.borderedProminent` Capsule chrome still hugs the
            // text. Pushing minWidth INTO the Label expands the text
            // frame the Capsule wraps around, so the chrome sizes
            // properly. Bumped 88 → 120 the same day: the banner
            // stretches edge-to-edge on wide windows and an 88pt CTA
            // looked tiny against ~1000pt of empty space. 120pt
            // gives the chrome more substantial weight without
            // pushing toward "comically big button" territory.
            Button {
                AppNavigation.shared.openInSettings(.permissions)
            } label: {
                Text("Fix").frame(minWidth: 120)
                    .foregroundStyle(Color.daisyTextOnAccent)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .tint(Color.daisyHomeAccent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        // 2026-05-25 — background + border unified across all three
        // Home banners (permissions / connectCalendar / deniedCalendar)
        // to the same `daisyAccent` chip at 0.20 opacity. Pre-fix the
        // permissions banner used `daisyWarning` (orange) and the
        // calendar one `daisyAccent` (cinnamon) — close enough on the
        // cream surface that the difference read as a rendering bug,
        // not as two intentional semantic variants. Semantic split now
        // lives entirely in the leading icon (warning triangle vs
        // calendar) and title text, while the chip chrome is one
        // family. Same colour, same opacity → fill and border merge
        // into one clean filled chip, no double-layer look.
        .background(
            Color.daisyHomeAccent.opacity(0.20),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.daisyHomeAccent.opacity(0.20), lineWidth: 0.5)
        )
    }

    /// "Microphone access needed" / "Accessibility access needed" /
    /// "Microphone & Accessibility access needed" — concrete enough
    /// to tell the user what'll break if they ignore the banner.
    private var missingPermissionsTitle: String {
        let mic = permissions.microphone != .granted
        let acc = permissions.accessibility != .granted
        switch (mic, acc) {
        case (true, true):   return String(localized: "Microphone & Accessibility access needed")
        case (true, false):  return String(localized: "Microphone access needed")
        case (false, true):  return String(localized: "Accessibility access needed")
        case (false, false): return ""
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
                    .foregroundStyle(Color.daisyTextOnAccent)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.daisyHomeAccent)
            .controlSize(.regular)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        // 2026-05-25 — joined the unified banner family (cinnamon
        // 0.20/0.20 chip) per the shape audit. Pre-fix this was
        // 0.06 fill + 0.18 border — a quieter half-cousin of the
        // four other Home banners. Egor sees this AND the calendar/
        // permissions banners in the same scroll column; the two
        // recipes read as "those two are different sections" not
        // "those are sibling info messages". One recipe, every time.
        .background(Color.daisyHomeAccent.opacity(0.20), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.daisyHomeAccent.opacity(0.20), lineWidth: 0.5)
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

    @ViewBuilder
    private var mainColumns: some View {
        if hasAnyCalendarSource {
            HStack(alignment: .top, spacing: Self.columnGap) {
                dayCard
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                recentSessionsSection
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(.horizontal, 24)
        } else {
            // No calendar connected: the day card still carries the lede +
            // open items (if any), stacked above the recordings.
            VStack(alignment: .leading, spacing: 8) {
                dayCard
                recentSessionsSection
            }
            .padding(.horizontal, 24)
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
        // 2026-05-25 — synced visual treatment to match
        // `permissionsAttentionBanner` (above): same border opacity
        // (0.25, was 0.20), explicit `.tint` on the button so it
        // renders as cinnamon-accent regardless of any inherited
        // system tint, caption trailing period dropped per the
        // caption-period rule (see business/projects/daisy → Brand
        // copy rules). Icon stays accent-cinnamon vs the permission
        // banner's warning-orange so the semantic split (info CTA vs
        // required-action warning) still reads.
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
            // minWidth inside the label — see comment on the Fix
            // button in `permissionsAttentionBanner` for why.
            Button {
                Task { _ = await calendar.requestAccess() }
                // MainView observes CalendarService.authorizationStatus
                // and wires AppSettings + service start on its own.
            } label: {
                Text("Connect").frame(minWidth: 120)
                    .foregroundStyle(Color.daisyTextOnAccent)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .tint(Color.daisyHomeAccent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        // 0.20 fill + 0.20 border — same unification as the
        // permissions banner above, see the comment there.
        .background(Color.daisyHomeAccent.opacity(0.20), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.daisyHomeAccent.opacity(0.20), lineWidth: 0.5)
        )
    }

    private var deniedCalendarCTA: some View {
        // 2026-05-25 — synced with the other two Home banners
        // (permissions + connectCalendar). Was missing the border
        // overlay entirely and used `.bordered` button instead of
        // `.borderedProminent` w/ explicit tint, so it read as a
        // visually weaker family member. Now matches the warning-
        // family treatment (orange icon + orange-tinted background +
        // matching border). Caption trailing period dropped per the
        // caption-period rule.
        HStack(spacing: 10) {
            // Icon in cinnamon to match the chip — same reasoning as
            // `permissionsAttentionBanner`. The glyph
            // (`calendar.badge.exclamationmark`) carries the
            // "something's wrong" semantic; the colour is harmony.
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
                    .foregroundStyle(Color.daisyTextOnAccent)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .tint(Color.daisyHomeAccent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        // Same `daisyAccent` chip at 0.20/0.20 as the other two
        // Home banners. Semantic "calendar is denied → user action
        // needed" stays in the warning-orange icon + title text.
        .background(Color.daisyHomeAccent.opacity(0.20), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.daisyHomeAccent.opacity(0.20), lineWidth: 0.5)
        )
    }

    // MARK: - Usage stats (words/min · total words · activity)

    /// Three Wispr-style widgets at the top of Home, all from the local
    /// `UsageStats` tracker (dictations + recordings). Hidden until
    /// there's at least one recorded session so a fresh install isn't
    /// greeted by zeros.
    @ViewBuilder
    private var statsSection: some View {
        if usage.totalCount > 0 {
            // One row, 1/4 + 1/4 + 2/4: the outer HStack splits the width
            // into two equal halves (nested pair vs heatmap), the nested
            // HStack splits its half again — exact quarters without
            // GeometryReader. `maxHeight: .infinity` on the number cards
            // stretches them to the heatmap's height so the row reads as
            // one aligned band.
            // Gutter = `columnGap` everywhere (also mainColumns below), so
            // the half-split boundary lines up with the calendar/recordings
            // band and every column gap on Home reads identical.
            HStack(alignment: .top, spacing: Self.columnGap) {
                HStack(spacing: Self.columnGap) {
                    fixesCard
                    wordsCard
                }
                .frame(maxWidth: .infinity)
                heatmapCard
                    .frame(maxWidth: .infinity)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
        }
    }

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
        // Horizontal inset comes from `mainColumns` — see upcomingSection.
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
