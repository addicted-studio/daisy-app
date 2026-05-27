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

    /// Cumulative rotation degrees for the calendar-refresh icon.
    /// Each tap adds 360°. Keeps spinning forward (never resets to
    /// 0) so consecutive taps animate smoothly.
    @State private var refreshRotation: Double = 0

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
                upcomingSection
                recentSessionsSection
                if showDestinationsHint { destinationsHint }
                Spacer(minLength: 0)
            }
            .padding(.top, 24)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task { await store.refresh() }
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
                .foregroundStyle(Color.daisyAccent)
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
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .tint(Color.daisyAccent)
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
            Color.daisyAccent.opacity(0.20),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.daisyAccent.opacity(0.20), lineWidth: 0.5)
        )
    }

    /// "Microphone access needed" / "Accessibility access needed" /
    /// "Microphone & Accessibility access needed" — concrete enough
    /// to tell the user what'll break if they ignore the banner.
    private var missingPermissionsTitle: String {
        let mic = permissions.microphone != .granted
        let acc = permissions.accessibility != .granted
        switch (mic, acc) {
        case (true, true):   return "Microphone & Accessibility access needed"
        case (true, false):  return "Microphone access needed"
        case (false, true):  return "Accessibility access needed"
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
                .foregroundStyle(Color.daisyAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Send sessions somewhere")
                    .font(.callout.weight(.medium))
                Text("Daisy can push finished sessions to Notion, Linear, Slack, or any MCP server — automatically or via the kebab menu in History.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button {
                AppNavigation.shared.section = .settings
            } label: {
                Text("Set up").frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.daisyAccent)
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
        .background(Color.daisyAccent.opacity(0.20), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.daisyAccent.opacity(0.20), lineWidth: 0.5)
        )
        .padding(.horizontal, 24)
    }

    // MARK: - Upcoming (Calendar)

    @ViewBuilder
    private var upcomingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader

            // Source-agnostic gating: show events if ANY calendar
            // source is live (Apple EventKit OR Google OAuth). The
            // "Connect Calendar" / "Calendar denied" CTAs only fire
            // when BOTH sources are unavailable — a user with only
            // Google connected should see their Google events here,
            // not a redundant "connect Apple Calendar" prompt.
            if hasAnyCalendarSource {
                eventsBody
            } else {
                switch calendar.authorizationStatus {
                case .denied, .restricted, .writeOnly:
                    deniedCalendarCTA
                case .notDetermined, .fullAccess:
                    connectCalendarCTA
                @unknown default:
                    connectCalendarCTA
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

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

    private var sectionHeader: some View {
        HStack(spacing: 8) {
            Text("Today")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer()
            if hasAnyCalendarSource, !todaysEvents.isEmpty {
                Text(eventCountLabel)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            // Manual refresh — EKEventStoreChanged occasionally misses
            // background updates from Google Calendar sync. One-click
            // re-fetch is cheap (local cache, ~50ms). Also the only
            // way to pull fresh Google events on demand since we have
            // no equivalent of EKEventStoreChanged for the OAuth path.
            if hasAnyCalendarSource {
                Button {
                    calendar.refresh()
                    withAnimation(.easeInOut(duration: 0.7)) {
                        refreshRotation += 360
                    }
                } label: {
                    Image(systemName: "arrow.trianglehead.2.clockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(refreshRotation))
                }
                .buttonStyle(.plain)
                .help("Refresh calendar")
            }
        }
    }

    private var eventCountLabel: String {
        let n = todaysEvents.count
        if n == 1 { return "1 event" }
        return "\(n) events"
    }

    @ViewBuilder
    private var eventsBody: some View {
        if todaysEvents.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                    .foregroundStyle(.secondary)
                Text("Nothing else scheduled today.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            // 2026-05-25 — pad + opacity matched to UpcomingEventRow
            // (10/8, gray .06) so the empty state slots in where the
            // event rows would have been, no layout jump as the day
            // empties out.
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.gray.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        } else {
            VStack(spacing: 6) {
                ForEach(todaysEvents) { event in
                    UpcomingEventRow(event: event) {
                        Task { await session.startFromMeeting(event) }
                    }
                }
            }
        }
    }

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
                .foregroundStyle(Color.daisyAccent)
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
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .tint(Color.daisyAccent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        // 0.20 fill + 0.20 border — same unification as the
        // permissions banner above, see the comment there.
        .background(Color.daisyAccent.opacity(0.20), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.daisyAccent.opacity(0.20), lineWidth: 0.5)
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
                .foregroundStyle(Color.daisyAccent)
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
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .tint(Color.daisyAccent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        // Same `daisyAccent` chip at 0.20/0.20 as the other two
        // Home banners. Semantic "calendar is denied → user action
        // needed" stays in the warning-orange icon + title text.
        .background(Color.daisyAccent.opacity(0.20), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.daisyAccent.opacity(0.20), lineWidth: 0.5)
        )
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
                    description: Text("Click Start recording to make your first one.")
                )
                .frame(maxWidth: .infinity)
                .frame(height: 160)
            } else {
                VStack(spacing: 4) {
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
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

}

// MARK: - Upcoming event row

private struct UpcomingEventRow: View {
    let event: DaisyMeeting   // DaisyMeeting now represents any event
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Calendar dot — colour from the EKCalendar if present
                Circle()
                    .fill(calendarDotColor)
                    .frame(width: 8, height: 8)

                Text(event.startDate, style: .time)
                    .font(.system(.callout, design: .monospaced))
                    .frame(width: 56, alignment: .leading)
                    .foregroundStyle(.secondary)

                Text(event.title)
                    .font(.callout)
                    .lineLimit(1)
                    .foregroundStyle(.primary)

                if let platform = event.meetingPlatform {
                    Text(platform.uppercased())
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.daisyAccent.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(Color.daisyAccent)
                }

                Spacer()

                Image(systemName: "record.circle")
                    .font(.callout)
                    .foregroundStyle(Color.daisyRecording)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(Color.gray.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help("Start recording for “\(event.title)”")
    }

    private var calendarDotColor: Color {
        if let hex = event.calendarColorHex, let parsed = Color(hex: hex) {
            return parsed
        }
        return Color.daisyTextTertiary
    }
}

private extension Color {
    /// Parse a `#RRGGBB` hex string into a Color. Returns nil on
    /// malformed input.
    init?(hex: String) {
        var str = hex.trimmingCharacters(in: .whitespaces)
        if str.hasPrefix("#") { str.removeFirst() }
        guard str.count == 6, let value = UInt32(str, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

// MARK: - Recent session row

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
                                .foregroundStyle(Color.daisyAccent)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(Color.gray.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
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
