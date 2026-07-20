//
//  DayCard.swift
//  Daisy
//
//  The single "your day" surface on Home — merges what used to be three
//  separate blocks (morning-brief card, the Today/Tomorrow calendar
//  column, and the standalone pre-meeting-brief card) into one card:
//
//    HEADER   greeting / TOMORROW + "N meetings · M open items" + refresh
//    LEDE     LLM intro (MorningBriefStore — local auto / cloud consent)
//    EVENTS   each meeting row: calendar dot · time · title; tap = start
//             recording; "Prep" disclosure expands the pre-meeting brief
//             inline; open items whose SOURCE session strongly matches
//             the meeting (shared attendee email) nest under it.
//    TO CLOSE remaining open items (not tied to today's meetings).
//
//  Grouping uses PreMeetingBriefStore.matchingSessions with
//  requireStrong: true — email-only, so a "Weekly sync" title collision
//  can't hang another client's task under the wrong meeting; anything
//  ambiguous stays in TO CLOSE. All local; nothing here talks to the
//  network (the lede/brief layers keep their own consent gates).
//

import SwiftUI

struct DayCard: View {
    let events: [DaisyMeeting]
    let isTomorrow: Bool
    let settings: AppSettings
    let onStartMeeting: (DaisyMeeting) -> Void

    @Bindable private var brief = MorningBriefStore.shared
    @Bindable private var actionItems = ActionItemStore.shared
    @Bindable private var store = SessionStore.shared

    /// Which event's Prep brief is expanded (one at a time).
    @State private var expandedPrepID: String?

    private static let maxTasksPerEvent = 3
    private static let maxStandaloneItems = 6

    var body: some View {
        let grouping = makeGrouping()
        let hasAnything = !events.isEmpty || !grouping.standalone.isEmpty
        if settings.morningBriefEnabled == false {
            // Brief disabled → plain agenda card (events only, no LLM/no tasks).
            if !events.isEmpty {
                card {
                    header(open: 0)
                    eventRows(grouping: grouping, showTasks: false)
                }
            }
        } else if hasAnything {
            card {
                header(open: actionItems.openCount)
                ledeBody
                if events.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "calendar")
                            .foregroundStyle(.secondary)
                        Text("No meetings today or tomorrow.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                } else {
                    eventRows(grouping: grouping, showTasks: true)
                }
                if !grouping.standalone.isEmpty {
                    Divider().padding(.vertical, 2)
                    Text("To close")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    itemsList(Array(grouping.standalone.prefix(Self.maxStandaloneItems)))
                    if grouping.standalone.count > Self.maxStandaloneItems {
                        Text("+ \(grouping.standalone.count - Self.maxStandaloneItems) more in recent sessions")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    // MARK: - Chrome

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.daisyBgElevated, in: RoundedRectangle(cornerRadius: 10))
        .task { await brief.prepare(settings: settings) }
    }

    private func header(open: Int) -> some View {
        HStack(spacing: 8) {
            Text(isTomorrow ? String(localized: "Tomorrow") : greeting)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer()
            Text(countsLabel(events: events.count, open: open))
                .font(.caption)
                .foregroundStyle(.tertiary)
            if case .ready = brief.ledeState {
                Button {
                    Task { await brief.regenerate(settings: settings) }
                } label: {
                    Image(systemName: "arrow.trianglehead.2.clockwise")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Refresh the brief")
            }
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12:  return String(localized: "Good morning")
        case 12..<18: return String(localized: "Your day")
        default:      return String(localized: "Your evening")
        }
    }

    private func countsLabel(events: Int, open: Int) -> String {
        var parts: [String] = []
        if events > 0 {
            parts.append(events == 1
                ? String(localized: "1 meeting")
                : String(localized: "\(events) meetings"))
        }
        if open > 0 {
            parts.append(open == 1
                ? String(localized: "1 open item")
                : String(localized: "\(open) open items"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Lede

    @ViewBuilder
    private var ledeBody: some View {
        switch brief.ledeState {
        case .generating:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading your day…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .ready(let summary):
            if !summary.summary.isEmpty {
                Text(summary.summary)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .needsConsent(let provider):
            HStack(spacing: 8) {
                Text("Summarize your day with \(provider)? Your open items are sent to \(provider).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Generate") {
                    Task { await brief.regenerate(settings: settings) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        case .idle, .unavailable:
            EmptyView()
        }
    }

    // MARK: - Events + nested tasks

    @ViewBuilder
    private func eventRows(grouping: Grouping, showTasks: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(events) { event in
                let key = PreMeetingBriefStore.key(for: event)
                eventRow(event, briefable: grouping.briefable.contains(key))
                if showTasks, let tasks = grouping.byEvent[key], !tasks.isEmpty {
                    itemsList(Array(tasks.prefix(Self.maxTasksPerEvent)))
                        .padding(.leading, 66)
                }
                if expandedPrepID == key {
                    PreMeetingBriefCard(meeting: event, settings: settings)
                        .padding(.leading, 24)
                }
            }
        }
    }

    private func eventRow(_ event: DaisyMeeting, briefable: Bool) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(dotColor(event))
                .frame(width: 8, height: 8)
            Text(event.startDate, style: .time)
                .font(.system(.callout, design: .monospaced))
                .frame(width: 46, alignment: .leading)
                .foregroundStyle(.secondary)
            // Tap the title area = start recording (same contract as the
            // old event row).
            Button {
                onStartMeeting(event)
            } label: {
                Text(event.title)
                    .font(.callout)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Start recording for “\(event.title)”"))
            Spacer()
            if briefable {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        let key = PreMeetingBriefStore.key(for: event)
                        expandedPrepID = (expandedPrepID == key) ? nil : key
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text("Prep")
                        Image(systemName: expandedPrepID == PreMeetingBriefStore.key(for: event)
                              ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(Color.daisyHomeAccent)
            }
        }
        .frame(minHeight: 24)
    }

    private func dotColor(_ event: DaisyMeeting) -> Color {
        if let hex = event.calendarColorHex, let parsed = Color(hexString: hex) {
            return parsed
        }
        return Color.daisyTextTertiary
    }

    // MARK: - Checkable items

    private func itemsList(_ items: [TrackedActionItem]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 8) {
                    Button {
                        actionItems.setDone(item, done: !item.isDone)
                    } label: {
                        Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 13))
                            .foregroundStyle(item.isDone ? Color.daisyHomeAccent : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.text)
                            .font(.caption)
                            .strikethrough(item.isDone)
                            .foregroundStyle(item.isDone ? .secondary : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(item.sessionTitle) · \(item.sessionDate.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    // MARK: - Grouping

    private struct Grouping {
        var byEvent: [String: [TrackedActionItem]] = [:]
        var standalone: [TrackedActionItem] = []
        var briefable: Set<String> = []
    }

    /// Assign each open item to at most ONE of the displayed events —
    /// only via a STRONG (shared attendee email) session match, so title
    /// collisions can't misfile a task. Ambiguous/unmatched items stay
    /// standalone. Also computes which events can show a Prep chip
    /// (provider-aware, same rule the brief store applies).
    private func makeGrouping() -> Grouping {
        var g = Grouping()
        let now = Date()
        var claimed = Set<String>()
        let open = actionItems.openItems
        // Effective-local: checks the CONFIGURED endpoint, not just the
        // provider kind — an MCP/Ollama URL pointed at a remote host
        // must NOT auto-run without the consent tap.
        let providerLocal = Summarizer.shared.providerIsEffectivelyLocal

        for event in events {
            let key = PreMeetingBriefStore.key(for: event)
            // Prep chip: any usable history under the provider's rules.
            let briefMatches = PreMeetingBriefStore.matchingSessions(
                for: event, in: store.sessions, now: now,
                limit: 1, requireStrong: !providerLocal
            )
            if !briefMatches.isEmpty { g.briefable.insert(key) }

            // Task nesting: STRONG matches only, regardless of provider.
            let strongIDs = Set(PreMeetingBriefStore.matchingSessions(
                for: event, in: store.sessions, now: now,
                limit: 5, requireStrong: true
            ).map(\.id))
            guard !strongIDs.isEmpty else { continue }
            let tasks = open.filter { !claimed.contains($0.id) && strongIDs.contains($0.sessionID) }
            if !tasks.isEmpty {
                g.byEvent[key] = tasks
                claimed.formUnion(tasks.map(\.id))
            }
        }
        g.standalone = open.filter { !claimed.contains($0.id) }
        return g
    }
}

private extension Color {
    /// Parse a `#RRGGBB` hex string. (Named `hexString:` to avoid
    /// colliding with other file-private `Color(hex:)` helpers.)
    init?(hexString: String) {
        var str = hexString.trimmingCharacters(in: .whitespaces)
        if str.hasPrefix("#") { str.removeFirst() }
        guard str.count == 6, let value = UInt32(str, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}
