//
//  DictationHistory.swift
//  Daisy
//
//  A short-lived, on-device log of what the user dictated. Push-to-talk
//  dictation is otherwise ephemeral — `DictationPaste` writes the text to
//  the clipboard, pastes it, then reverts the clipboard ~10 s later — so
//  once the transcript lands in the user's field there is no record of it
//  anywhere. That's usually fine, but the common "wait, what did I just
//  say?" / "I dictated that into the wrong window" cases have no recovery.
//  This store keeps a rolling 24-hour history so the user can glance back
//  and re-copy a recent dictation.
//
//  Deliberately minimal and private:
//   - Local only. A single JSON blob in UserDefaults — never synced,
//     never sent anywhere. Same persistence shape as
//     `DictationDictionary`.
//   - Self-pruning. Anything older than `retention` (24 h) is swept on
//     load and on every `record(_:)`, so the log can't silently grow into
//     a long-lived archive of everything the user ever dictated.
//   - Bounded. Even within the window we cap at `maxEntries` so a burst of
//     dictations can't bloat UserDefaults.
//
//  @MainActor: mirrors `DictationDictionary`. `record(_:)` is called on
//  the MainActor-isolated dictation paste path (`DictationPaste.handle`)
//  and the list is read/cleared from the Settings UI (also MainActor), so
//  every touchpoint is a plain same-actor call with no hop.
//

import Foundation
import Observation
import os

/// One recorded dictation: the text that was pasted (dictionary already
/// applied) plus when it happened.
///
/// `Identifiable` so SwiftUI's `ForEach` can track rows; `Equatable` so
/// the list can diff cheaply.
struct DictationEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    /// The pasted text, exactly as it landed in the user's field
    /// (custom-vocabulary replacements already applied upstream).
    var text: String
    /// When the dictation was recorded.
    var date: Date
}

@MainActor
@Observable
final class DictationHistory {
    static let shared = DictationHistory()

    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "DictationHistory")

    /// UserDefaults key for the persisted JSON array of entries.
    private static let defaultsKey = "daisy.dictationHistory"

    /// How long an entry is kept before it's swept. Tunable — bump this if
    /// the 24-hour window proves too short in practice. Entries past this
    /// age are dropped on load and on every `record(_:)`.
    static let retention: TimeInterval = 24 * 60 * 60

    /// Hard cap on stored entries, independent of age. Bounds the size of
    /// the UserDefaults blob if the user dictates heavily inside one
    /// window. We keep the most recent `maxEntries` (the list is
    /// newest-first, so this is a simple prefix).
    static let maxEntries = 200

    /// Newest-first list of recent dictations. Observable so the Settings
    /// list re-renders on add/clear. Persisted on every mutation via
    /// `didSet`. Always swept (age + cap) before it's stored, so reads see
    /// only live, bounded data.
    private(set) var entries: [DictationEntry] {
        didSet { persist() }
    }

    private init() {
        // Restore from UserDefaults, then immediately sweep stale entries
        // so a log left over from days ago doesn't resurface. A
        // missing/corrupt blob starts empty rather than crashing — the
        // history is non-critical and a bad decode shouldn't take down
        // dictation.
        let restored: [DictationEntry]
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([DictationEntry].self, from: data) {
            restored = decoded
        } else {
            restored = []
        }
        // Assign through a local first (not `entries`) so we can compute
        // the swept value before the stored property — and its `didSet`
        // persist — ever sees the un-swept restore.
        entries = Self.swept(restored)
    }

    // MARK: - Mutation

    /// Log a dictation. The text should be the final pasted string (with
    /// the dictionary already applied) so the history matches what the
    /// user actually got. Whitespace-only / empty transcripts are ignored
    /// — there's nothing useful to re-copy. Newest entries go to the
    /// front; the list is then swept (age) and capped (count).
    func record(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Store the original text (not the trimmed copy) so leading/
        // trailing formatting the user dictated is preserved on re-copy;
        // we only trim to decide whether there's anything worth keeping.
        let entry = DictationEntry(text: text, date: Date())
        entries = Self.swept([entry] + entries)
    }

    /// Drop the entire history. Used by the "Clear history" control.
    func clear() {
        guard !entries.isEmpty else { return }
        entries = []
    }

    // MARK: - Sweep

    /// Return `list` with stale entries removed and the result bounded to
    /// `maxEntries`, newest-first. `nonisolated static` so it's trivially
    /// unit-testable and carries no actor or instance state.
    ///
    /// Order: filter by age first (cheap, and it's what bounds *time*),
    /// then sort newest-first defensively (callers prepend, but a corrupt
    /// or hand-edited blob might not be ordered), then take the prefix.
    nonisolated static func swept(_ list: [DictationEntry]) -> [DictationEntry] {
        let cutoff = Date().addingTimeInterval(-retention)
        let live = list
            .filter { $0.date >= cutoff }
            .sorted { $0.date > $1.date }
        return Array(live.prefix(maxEntries))
    }

    // MARK: - Persistence

    private func persist() {
        do {
            let data = try JSONEncoder().encode(entries)
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        } catch {
            log.error("Couldn't persist dictation history: \(error.localizedDescription, privacy: .public)")
        }
    }
}
