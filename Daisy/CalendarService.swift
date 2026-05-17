//
//  CalendarService.swift
//  Daisy
//
//  EventKit-backed calendar awareness. Reads the next 24h of events,
//  surfaces "is this a meeting?" by detecting Zoom / Google Meet /
//  Teams / Webex / Whereby / Jitsi URLs in event.location / .url /
//  .notes, and emits a callback when one starts so RecordingSession
//  can auto-record.
//
//  Plays nicely with `MeetingDetector` (NSWorkspace-based, watches
//  Zoom.app / Teams.app launches). The two surfaces overlap for
//  native-app meetings; CalendarService is the only path for
//  browser-based meetings (Google Meet in Chrome, where the
//  bundle id is just "com.google.Chrome").
//
//  ─── Architecture ────────────────────────────────────────────────
//
//  The `EKEventStore` is a singleton — losing the store invalidates
//  every `EKEvent` reference we've handed out (they're lazy proxies
//  to a Core Data row inside the store). For this reason
//  `CalendarService` ONLY returns immutable `DaisyMeeting` value
//  types outside its own boundary.
//
//  ─── Permission flow (macOS 14+) ─────────────────────────────────
//
//  Apple split calendar access into `.writeOnly` and `.fullAccess`
//  on macOS 14 (Sonoma). Daisy needs `.fullAccess` — we read events,
//  we never write. Info.plist must contain
//  `NSCalendarsFullAccessUsageDescription` (with
//  `NSCalendarsUsageDescription` as legacy fallback). No sandbox
//  entitlement key is required for AppKit / SwiftUI apps — TCC is
//  driven entirely by the Info.plist strings.
//

import AppKit
import EventKit
import Foundation
import Observation

// MARK: - DTO

/// Immutable snapshot of an EKEvent. Crossing the CalendarService
/// boundary as EKEvent is unsafe (EKEvent is a proxy into the
/// store's Core Data) so we always project to this struct.
struct DaisyMeeting: Identifiable, Hashable, Sendable {
    /// External (provider-side) identifier — survives local re-sync,
    /// matches across devices via iCloud. Preferred for long-term
    /// transcript-to-meeting binding.
    let externalID: String?
    /// Local EKEvent identifier — only stable within this Mac's
    /// EventKit store. Use as fallback.
    let localID: String
    let title: String
    let startDate: Date
    let endDate: Date
    let location: String?
    let notes: String?
    /// The first detected meeting URL (Zoom / Meet / Teams / etc.).
    /// `nil` means this event is not a recordable meeting.
    let meetingURL: URL?
    /// Provider slug ("zoom", "meet", "teams", "webex", "whereby",
    /// "jitsi") — for UI badges.
    let meetingPlatform: String?
    /// Calendar colour for UI dot.
    let calendarColorHex: String?

    var id: String { localID }
    var isMeeting: Bool { meetingURL != nil }
}

// MARK: - Service

@MainActor
@Observable
final class CalendarService {
    static let shared = CalendarService()

    /// Cached, filtered upcoming meetings — only events with a
    /// detected meeting URL. UI binds directly to this.
    var upcomingMeetings: [DaisyMeeting] = []

    /// Cached upcoming events (with or without a meeting URL) for any
    /// UI that wants to show the full calendar, not just meetings.
    var upcomingEvents: [DaisyMeeting] = []

    /// Last permission state from EventKit. Trips UI between
    /// "Connect Calendar" CTA and the events list.
    var authorizationStatus: EKAuthorizationStatus =
        EKEventStore.authorizationStatus(for: .event)

    // ─── Internals ──────────────────────────────────────────────────

    private let store = EKEventStore()
    private var storeChangeObserver: NSObjectProtocol?
    private var pollTimer: Timer?
    private var firedEventIDs: Set<String> = []

    private var onMeetingStart: ((DaisyMeeting) -> Void)?
    private var lookaheadHours: Int = 24
    private var autoStartEnabled: Bool = false

    private init() {}

    // MARK: - Permission

    /// Ask the user for full calendar access. Returns the resulting
    /// status. Safe to call multiple times — EventKit no-ops if the
    /// state is already determined.
    @discardableResult
    func requestAccess() async -> EKAuthorizationStatus {
        do {
            _ = try await store.requestFullAccessToEvents()
        } catch {
            // Denied or system error — fall through to the
            // authoritative status read below.
        }
        let status = EKEventStore.authorizationStatus(for: .event)
        authorizationStatus = status
        return status
    }

    /// Opens System Settings → Privacy → Calendars so the user can
    /// flip access back on after a denial. No-op if access is already
    /// granted.
    func openSystemSettingsIfDenied() {
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .denied || status == .restricted || status == .writeOnly else { return }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Fetch + observe

    /// Begin maintaining the `upcomingMeetings` / `upcomingEvents`
    /// caches. Idempotent — calling again replaces the previous
    /// configuration (handy when the user changes auto-start prefs).
    func start(
        lookaheadHours: Int = 24,
        autoStartOnMeeting: Bool,
        onMeetingStart: @escaping (DaisyMeeting) -> Void
    ) {
        self.lookaheadHours = lookaheadHours
        self.autoStartEnabled = autoStartOnMeeting
        self.onMeetingStart = onMeetingStart

        // Subscribe to EventKit change notifications (covers calendar
        // sync, user-edits in Calendar.app, iCloud reconcile, etc.).
        if storeChangeObserver == nil {
            storeChangeObserver = NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged,
                object: store,
                queue: .main
            ) { [weak self] _ in
                // The notification handler is @Sendable in Swift 6.
                // Re-capture weak self inside the Task so we don't
                // strongly retain the service across the actor hop.
                Task { @MainActor [weak self] in self?.refresh() }
            }
        }

        // Start the rolling poll — one timer for all events, 15s
        // tick. Lighter than per-event NSTimer.
        if pollTimer == nil {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.tick() }
            }
        }

        refresh()
    }

    /// Stop observing and clear caches. Called when the user revokes
    /// the auto-start preference or when the app is shutting down.
    func stop() {
        if let observer = storeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            storeChangeObserver = nil
        }
        pollTimer?.invalidate()
        pollTimer = nil
        onMeetingStart = nil
        upcomingMeetings = []
        upcomingEvents = []
        firedEventIDs = []
    }

    /// Force a re-fetch of the events window. Cheap (EventKit reads
    /// from a local cache, not the network).
    func refresh() {
        let status = EKEventStore.authorizationStatus(for: .event)
        authorizationStatus = status
        guard status == .fullAccess else {
            upcomingMeetings = []
            upcomingEvents = []
            return
        }

        let now = Date()
        let end = now.addingTimeInterval(TimeInterval(lookaheadHours * 3600))
        let calendars = store.calendars(for: .event)
        let predicate = store.predicateForEvents(
            withStart: now,
            end: end,
            calendars: calendars
        )

        let events = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }

        let projected = events.compactMap(DaisyMeeting.init(ekEvent:))
        upcomingEvents = projected
        upcomingMeetings = projected.filter(\.isMeeting)

        // Prune the fired-set — drop ids that have rotated out of
        // the visible window so a repeated daily standup re-triggers
        // tomorrow.
        let visibleIDs = Set(projected.map(\.localID))
        firedEventIDs = firedEventIDs.intersection(visibleIDs)
    }

    // MARK: - "Meeting starting now" tick

    private func tick() {
        guard autoStartEnabled, let onMeetingStart else { return }

        let now = Date()
        for meeting in upcomingMeetings {
            guard !firedEventIDs.contains(meeting.localID) else { continue }
            let delta = meeting.startDate.timeIntervalSince(now)
            // Fire window: from -120s (caught running 2 min late) to
            // +30s (about to start). Past 2 min late, the user gets a
            // separate UI banner — see notes in research log — but we
            // don't surface that here, only fire the silent auto-
            // record path.
            if delta <= 30 && delta >= -120 {
                firedEventIDs.insert(meeting.localID)
                onMeetingStart(meeting)
            }
        }
    }

    // MARK: - Hot-reconfigure (no need to stop/start)

    func setAutoStart(_ enabled: Bool) { autoStartEnabled = enabled }
}

// MARK: - EKEvent → DaisyMeeting projection

private extension DaisyMeeting {
    nonisolated init?(ekEvent: EKEvent) {
        // `eventIdentifier` is technically optional on EKEvent but in
        // practice is always present for store-fetched events.
        guard let localID = ekEvent.eventIdentifier else { return nil }

        let detected = Self.detectMeetingURL(in: ekEvent)
        let cgColor = ekEvent.calendar?.cgColor
        let hex = cgColor.flatMap(Self.hexString(from:))

        self.init(
            externalID: ekEvent.calendarItemExternalIdentifier,
            localID: localID,
            title: ekEvent.title ?? "Untitled",
            startDate: ekEvent.startDate,
            endDate: ekEvent.endDate ?? ekEvent.startDate.addingTimeInterval(3600),
            location: ekEvent.location,
            notes: ekEvent.notes,
            meetingURL: detected?.url,
            meetingPlatform: detected?.platform,
            calendarColorHex: hex
        )
    }

    /// Inspect location → url → notes for a known meeting platform
    /// URL. Order matters: location is where most Zoom invites end
    /// up, then EKEvent.url (Apple Calendar's native URL field),
    /// then notes (Google Calendar dumps the link here).
    nonisolated static func detectMeetingURL(in event: EKEvent) -> (platform: String, url: URL)? {
        let haystacks: [String] = [
            event.location,
            event.url?.absoluteString,
            event.notes,
        ].compactMap { $0 }

        for text in haystacks {
            for (platform, pattern) in meetingPatterns {
                if let match = text.range(of: pattern, options: .regularExpression) {
                    let raw = String(text[match])
                    if let url = URL(string: raw) {
                        return (platform, url)
                    }
                }
            }
        }
        return nil
    }

    /// Platform → regex pattern. We use NSRegularExpression-style
    /// patterns (Swift's `firstMatch(of: #/.../#)` is slick but the
    /// closed-over Regex type complicates an array of tuples).
    nonisolated static let meetingPatterns: [(platform: String, pattern: String)] = [
        ("zoom",    #"https?://[\w.-]*zoom\.us/(?:j|my|wc|s)/[^\s<>"']+"#),
        ("meet",    #"https?://meet\.google\.com/[a-z0-9\-]+(?:\?[^\s<>"']*)?"#),
        ("teams",   #"https?://teams\.(?:microsoft|live)\.com/(?:l/meetup-join|meet)/[^\s<>"']+"#),
        ("webex",   #"https?://[\w.-]*webex\.com/(?:meet/[^\s<>"']+|[^\s<>"']*/j\.php\?[^\s<>"']+)"#),
        ("whereby", #"https?://whereby\.com/[\w\-]+"#),
        ("jitsi",   #"https?://meet\.jit\.si/[^\s<>"']+"#),
    ]

    /// Calendar colour → hex like "#7BAE8E".
    nonisolated static func hexString(from color: CGColor) -> String? {
        guard let comps = color.components, comps.count >= 3 else { return nil }
        let r = Int((comps[0] * 255).rounded())
        let g = Int((comps[1] * 255).rounded())
        let b = Int((comps[2] * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
