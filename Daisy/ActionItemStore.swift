//
//  ActionItemStore.swift
//  Daisy
//
//  Open-loop tracking over the action items the summarizer already
//  extracts. Summaries only store flat strings; this store gives each
//  item a stable identity (sessionID + index), remembers which ones the
//  user checked off or dismissed, and exposes the OPEN set — the raw
//  material for the morning brief ("you still owe Maria the quote").
//  States persist in UserDefaults keyed by item id; the item list itself
//  is always rebuilt from the session corpus, so re-summarizing a
//  session naturally refreshes its items.
//

import Foundation
import Observation

struct TrackedActionItem: Identifiable, Sendable, Equatable {
    /// Stable identity: "<sessionID>#<index>" — survives app restarts as
    /// long as the summary isn't regenerated (acceptable: a re-summary
    /// means the items themselves changed).
    let id: String
    let text: String
    let sessionID: String
    let sessionTitle: String
    let sessionDate: Date
    var isDone: Bool
}

@MainActor
@Observable
final class ActionItemStore {
    static let shared = ActionItemStore()

    /// Items from the recent window, newest session first. Includes done
    /// ones (UI shows them struck-through until the window slides past).
    private(set) var items: [TrackedActionItem] = []

    /// How far back to harvest items. Old promises either got done or
    /// went stale — two weeks keeps the list honest.
    private static let windowDays = 14
    private static let stateKey = "daisy.actionItemStates"

    /// Persisted per-item state: true = done/dismissed.
    @ObservationIgnored
    private var doneStates: [String: Bool]

    private init() {
        if let dict = UserDefaults.standard.dictionary(forKey: Self.stateKey) as? [String: Bool] {
            doneStates = dict
        } else {
            doneStates = [:]
        }
    }

    var openItems: [TrackedActionItem] { items.filter { !$0.isDone } }
    var openCount: Int { openItems.count }

    /// Rebuild from the session corpus (call after SessionStore.refresh).
    /// Also prunes persisted states for items that no longer exist so the
    /// defaults blob can't grow forever.
    func rebuild(from sessions: [StoredSession]) {
        let cutoff = Calendar.current.date(
            byAdding: .day, value: -Self.windowDays, to: Date()
        ) ?? .distantPast

        var rebuilt: [TrackedActionItem] = []
        for session in sessions where session.startedAt >= cutoff {
            guard let summary = session.summary else { continue }
            for (idx, text) in summary.actionItems.enumerated() {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let id = "\(session.id)#\(idx)"
                rebuilt.append(TrackedActionItem(
                    id: id,
                    text: trimmed,
                    sessionID: session.id,
                    sessionTitle: session.title,
                    sessionDate: session.startedAt,
                    isDone: doneStates[id] ?? false
                ))
            }
        }
        rebuilt.sort { $0.sessionDate > $1.sessionDate }
        items = rebuilt

        // Prune states for vanished items (aged out / session deleted).
        let liveIDs = Set(rebuilt.map(\.id))
        let pruned = doneStates.filter { liveIDs.contains($0.key) }
        if pruned.count != doneStates.count {
            doneStates = pruned
            persist()
        }
    }

    func setDone(_ item: TrackedActionItem, done: Bool) {
        doneStates[item.id] = done
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx].isDone = done
        }
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(doneStates, forKey: Self.stateKey)
    }
}
