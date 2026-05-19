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
            Button("Set up") {
                AppNavigation.shared.section = .settings
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.daisyAccent)
            .controlSize(.regular)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.daisyAccent.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.daisyAccent.opacity(0.18), lineWidth: 0.5)
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
    /// pill in the section header.
    private var hasAnyCalendarSource: Bool {
        calendar.authorizationStatus == .fullAccess || google.isConnected
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
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.gray.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
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
        HStack(spacing: 10) {
            Image(systemName: "calendar.badge.plus")
                .font(.title3)
                .foregroundStyle(Color.daisyAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text("See your meetings here")
                    .font(.callout.weight(.medium))
                Text("Connect Calendar to surface today's events and auto-start recordings when they begin.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button("Connect") {
                Task { _ = await calendar.requestAccess() }
                // MainView observes CalendarService.authorizationStatus
                // and wires AppSettings + service start on its own.
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.daisyAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.daisyAccent.opacity(0.20), lineWidth: 0.5)
        )
    }

    private var deniedCalendarCTA: some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.title3)
                .foregroundStyle(Color.daisyWarning)
            VStack(alignment: .leading, spacing: 2) {
                Text("Calendar access is off")
                    .font(.callout.weight(.medium))
                Text("Grant access in System Settings → Privacy → Calendars to see upcoming meetings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button("Open Settings") {
                calendar.openCalendarPrivacy()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.daisyWarning.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
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
