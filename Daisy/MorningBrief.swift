//
//  MorningBrief.swift
//  Daisy
//
//  The morning brief: once per day, assemble today's calendar + the open
//  action items (ActionItemStore) and — when a provider is available —
//  an LLM "what matters today" lede with 2-4 Focus priorities. The
//  checkable open-items list on the card is the source of truth; the LLM
//  layer is narrative on top, and the card degrades gracefully to plain
//  meetings + checkboxes when no provider can run.
//
//  Privacy contract mirrors the pre-meeting brief: a LOCAL summary
//  provider auto-generates; a CLOUD provider waits for an explicit
//  "Generate" tap (.needsConsent). Everything else is on-device.
//
//  Also owns the optional daily notification (a repeating local
//  UNCalendarNotificationTrigger at the user's chosen time). The
//  notification body is deliberately generic — counts aren't known at
//  schedule time and transcript content never belongs in a banner.
//

import Foundation
import Observation
@preconcurrency import UserNotifications
import os

@MainActor
@Observable
final class MorningBriefStore {
    static let shared = MorningBriefStore()

    enum LedeState: Equatable {
        case idle
        case generating
        /// LLM lede + focus priorities are ready.
        case ready(MeetingSummary)
        /// Cloud provider selected — waiting for an explicit tap.
        case needsConsent(String)
        /// Provider can't run / failed — card shows without the lede.
        case unavailable
    }

    private(set) var ledeState: LedeState = .idle

    @ObservationIgnored
    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "MorningBrief")
    private static let generatedDayKeyKey = "daisy.morningBrief.generatedDay"

    private init() {}

    /// Day key the current lede was generated for (persisted so an app
    /// relaunch the same morning doesn't spend a second LLM call).
    private var generatedDayKey: String? {
        get { UserDefaults.standard.string(forKey: Self.generatedDayKeyKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.generatedDayKeyKey) }
    }

    /// Idempotent daily prepare — call from the card's `.task`. Rebuilds
    /// the open-items list, then generates the lede once per local day
    /// (local provider) or parks at `.needsConsent` (cloud provider).
    func prepare(settings: AppSettings, force: Bool = false) async {
        guard settings.morningBriefEnabled else { return }

        ActionItemStore.shared.rebuild(from: SessionStore.shared.sessions)

        let today = UsageStats.dayKey(for: Date())
        if !force, generatedDayKey == today, case .ready = ledeState { return }
        if case .generating = ledeState { return }

        let events = Self.todaysEvents()
        let openItems = ActionItemStore.shared.openItems
        // Nothing to brief about — the card renders its own empty state;
        // don't spend an LLM call narrating an empty day.
        guard !events.isEmpty || !openItems.isEmpty else {
            ledeState = .unavailable
            return
        }

        // Effective-local (configured endpoint, not provider kind) —
        // remote-pointed MCP/Ollama must not auto-run. See Summarizer.
        let providerLocal = Summarizer.shared.providerIsEffectivelyLocal
        if !providerLocal && !force {
            ledeState = .needsConsent(Summarizer.shared.providerKind.shortName)
            return
        }
        guard Summarizer.shared.availability == .available else {
            ledeState = .unavailable
            return
        }

        ledeState = .generating
        let dossier = Self.buildDossier(events: events, openItems: openItems)
        do {
            let summary = try await Summarizer.shared.runProbe(
                transcript: dossier,
                title: "Morning brief",
                localeHint: nil,
                task: .morningBrief
            )
            ledeState = .ready(summary)
            generatedDayKey = today
            log.info("Morning brief lede ready (\(events.count) meetings, \(openItems.count) open items)")
        } catch {
            ledeState = .unavailable
            log.error("Morning brief lede failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Explicit tap — consent for a cloud provider / manual refresh.
    func regenerate(settings: AppSettings) async {
        generatedDayKey = nil
        ledeState = .idle
        await prepare(settings: settings, force: true)
    }

    // MARK: - Sources

    /// Today's still-relevant events (same calendar-day rule as Home).
    static func todaysEvents() -> [DaisyMeeting] {
        let cal = Calendar.current
        let now = Date()
        return CalendarService.shared.upcomingEvents.filter { event in
            cal.isDate(event.startDate, inSameDayAs: now) && event.endDate > now
        }
    }

    nonisolated static func buildDossier(events: [DaisyMeeting], openItems: [TrackedActionItem]) -> String {
        var out = "TODAY'S CALENDAR:\n"
        if events.isEmpty {
            out += "(no meetings scheduled)\n"
        } else {
            let tf = DateFormatter()
            tf.dateFormat = "HH:mm"
            for e in events {
                out += "- \(tf.string(from: e.startDate)) \(e.title)"
                if !e.attendees.isEmpty {
                    out += " (with \(e.attendees.prefix(4).joined(separator: ", ")))"
                }
                out += "\n"
            }
        }

        out += "\nOPEN ACTION ITEMS (from the user's recent meetings):\n"
        if openItems.isEmpty {
            out += "(none)\n"
        } else {
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .none
            // Bound the dossier: 40 items is far beyond a sane open list.
            for item in openItems.prefix(40) {
                out += "- [\(df.string(from: item.sessionDate)) · \(item.sessionTitle)] \(item.text)\n"
            }
        }
        return out
    }

    // MARK: - Daily notification

    private static let notificationID = "daisy.morningBrief.daily"

    /// (Re)schedule the repeating daily notification per settings. Call
    /// on launch and whenever the toggle/time changes. Generic content —
    /// the banner's job is to bring the user to the card, not leak it.
    static func rescheduleNotification(settings: AppSettings) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [notificationID])
        guard settings.morningBriefEnabled, settings.morningBriefNotifyEnabled else { return }
        // Capture only a Sendable scalar; build the request on a MainActor
        // hop inside each callback. UNUserNotificationCenter /
        // UNNotificationRequest are NOT Sendable and Swift 6 rejects
        // capturing them in the @Sendable completions (see the identical
        // note in SilencePromptNotification.swift).
        let minutes = settings.morningBriefNotifyMinutes

        UNUserNotificationCenter.current().getNotificationSettings { s in
            switch s.authorizationStatus {
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
                    if granted { Task { @MainActor in addRequest(minutes: minutes) } }
                }
            case .authorized, .provisional:
                Task { @MainActor in addRequest(minutes: minutes) }
            case .denied, .ephemeral:
                break
            @unknown default:
                break
            }
        }
    }

    private static func addRequest(minutes: Int) {
        var comps = DateComponents()
        comps.hour = minutes / 60
        comps.minute = minutes % 60
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Your morning brief is ready")
        content.body = String(localized: "Today's meetings and your open items are waiting in Daisy.")
        content.sound = nil  // morning — no need to be loud
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: notificationID, content: content, trigger: trigger),
            withCompletionHandler: nil
        )
    }
}
