//
//  LayoutFixUndo.swift
//  Daisy
//
//  Makes a wrong automatic layout fix cheap to reverse — the whole
//  reason Punto Switcher's users tolerated an aggressive corrector was
//  that a mistake cost one press of Break. Ours stays conservative
//  (see LayoutFix.judge), but a bad call should still cost one
//  keypress, not a manual retype. That's what this file is for.
//
//  Scope, deliberately narrow: only the two AUTOMATIC paths
//  (LayoutAutoFix's "before the boundary" and "after the fact") ever
//  record something here. The fix key and a mouse selection are things
//  the user asked for — pressing the key again already converts them
//  back, so an undo record would just be a second, redundant way to
//  do the same thing, and selection undo would have to fight
//  PasteboardProxy over the clipboard for no benefit.
//

import Foundation
import Observation

/// The last automatic fix, kept just long enough for one keypress to
/// undo it.
@MainActor
final class LayoutFixUndo {
    static let shared = LayoutFixUndo()

    struct Record {
        /// The word as the person typed it, no boundary. This is what
        /// gets retyped, and the exceptions set's key.
        let originalWord: String
        /// What ended the word (space, comma, Return, …). Always
        /// present: both automatic paths only ever settle once a
        /// boundary has actually fired.
        let boundary: Character
        /// The fix's output, word only, no boundary.
        let replacementWord: String
        let bundleID: String
        /// The layout to make active again on undo — i.e. whatever was
        /// active before `settle` switched it, captured at that moment.
        /// `nil` when `settle` didn't switch anything, matching the
        /// "nothing to put back" case.
        let restoreLayoutID: String?
        let at: Date

        /// What's on screen right now: fix output + boundary. What
        /// undo deletes, and what it compares the caret against.
        var replacementText: String { replacementWord + String(boundary) }
        /// What undo retypes.
        var originalText: String { originalWord + String(boundary) }
    }

    /// How long an undo stays offered. Long enough to notice the
    /// mistake and reach for the key; short enough that pressing it
    /// after several more words have gone by does ordinary key work
    /// instead of surprising someone by rewriting a sentence they've
    /// moved past.
    private static let window: TimeInterval = 5

    private(set) var pending: Record?

    private init() {}

    func record(_ record: Record) {
        pending = record
    }

    /// The pending record, if it's still within the undo window and
    /// for the same app — `nil` otherwise, which the caller treats as
    /// "nothing to undo". Cross-app is refused outright: the fix and
    /// the undo key press have to happen in the same place, or this is
    /// somebody else's fix key press in a different window.
    func fresh(bundleID: String) -> Record? {
        guard let pending,
              Date().timeIntervalSince(pending.at) <= Self.window,
              pending.bundleID == bundleID
        else { return nil }
        return pending
    }

    /// Second press in a row after a successful undo is ordinary key
    /// work, not an undo of the undo — callers clear this the moment
    /// undo succeeds.
    func clear() {
        pending = nil
    }
}

/// Words the automatic fixer has been told, via undo, never to touch
/// again. A single wrong call is now one keypress AND one lesson
/// learned, so the same slang word or product name doesn't keep
/// getting "corrected" every time it's typed.
@MainActor
@Observable
final class LayoutFixExceptions {
    static let shared = LayoutFixExceptions()

    /// Past this many words the oldest exceptions age out. Not a
    /// permanent blocklist — the point is "stop re-annoying me about
    /// the word I just undid", and a cap keeps years of one-off typos
    /// from silently growing a plist forever.
    static let cap = 2_000

    private static let defaultsKey = "daisy.layoutFixExceptions"

    private let defaults: UserDefaults

    /// Oldest first — insertion order, needed for eviction. `contains`
    /// runs on the hottest path `judge` has (every automatically-typed
    /// word), so a parallel `Set` gives it O(1) instead of a linear
    /// scan through up to 2,000 strings.
    private(set) var words: [String]
    private var lookup: Set<String>

    var count: Int { words.count }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.stringArray(forKey: Self.defaultsKey) ?? []
        words = stored
        lookup = Set(stored)
    }

    /// Case-insensitive: the word buffer holds exactly what was typed,
    /// and "Ghbdtn" at the start of a sentence has to match the
    /// "ghbdtn" undone moments earlier mid-sentence.
    func contains(_ word: String) -> Bool {
        lookup.contains(word.lowercased())
    }

    func add(_ word: String) {
        let key = word.lowercased()
        guard !lookup.contains(key) else { return }
        words.append(key)
        lookup.insert(key)
        if words.count > Self.cap {
            let overflow = words.count - Self.cap
            for evicted in words.prefix(overflow) { lookup.remove(evicted) }
            words.removeFirst(overflow)
        }
        persist()
    }

    func clear() {
        words.removeAll()
        lookup.removeAll()
        persist()
    }

    private func persist() {
        defaults.set(words, forKey: Self.defaultsKey)
    }
}
