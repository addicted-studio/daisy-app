//
//  DictationDictionary.swift
//  Daisy
//
//  User-defined custom-vocabulary substitutions applied to dictation
//  output just before it's pasted. The speech model reliably mishears
//  proper nouns, brands, and jargon ("claude" → should be "Claude",
//  "sazzi" → "Sazzi", "daisy app" → "Daisy"); this store lets the user
//  curate a small replacement table that fixes those after transcription
//  but before the text lands in their active field.
//
//  Why a plain ordered list (not a dict): order is user-meaningful.
//  Two rules can target overlapping text ("daisy" and "daisy app"), and
//  the user controls precedence by reordering. `apply(to:)` additionally
//  sorts by `from` length descending at match time so a longer phrase
//  always wins over a shorter prefix regardless of row order — but the
//  stored order is preserved for the editor and for ties.
//
//  Matching is word-boundary anchored so "cat" → "dog" never corrupts
//  "category". Case-insensitive by default (most fixes are casing fixes,
//  and the user dictates lower-case); per-rule `caseSensitive` opt-in for
//  the rare case where the source casing matters.
//
//  Persistence: a single JSON blob in UserDefaults under
//  `daisy.dictationDictionary`. The table is tiny (a handful of short
//  strings) so there's no reason to spread it across files the way
//  `SpeakerProfileStore` does.
//
//  @MainActor: the store is read on the MainActor-isolated dictation
//  paste path (`DictationPaste.handle`) and mutated from the Settings
//  editor (also MainActor). Keeping it MainActor means `apply(to:)` is a
//  plain same-actor call with no hop or snapshot at the call site.
//

import Foundation
import Observation
import os
import SwiftUI  // for Array.move(fromOffsets:toOffset:) used in move(from:to:)

/// One substitution rule: replace occurrences of `from` with `to`.
/// `Identifiable` so SwiftUI's `ForEach` can track rows across edits and
/// reorders; `Equatable` so the editor can diff cheaply.
struct DictationReplacement: Codable, Identifiable, Equatable {
    var id = UUID()
    /// The (mis)heard text to look for. Matched on word boundaries.
    var from: String
    /// What to substitute in its place.
    var to: String
    /// When false (default), matching ignores case ("claude", "Claude",
    /// "CLAUDE" all match). When true, only an exact-case occurrence of
    /// `from` is replaced.
    var caseSensitive: Bool = false
}

@MainActor
@Observable
final class DictationDictionary {
    static let shared = DictationDictionary()

    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "DictationDictionary")

    /// UserDefaults key for the persisted JSON array of rules.
    private static let defaultsKey = "daisy.dictationDictionary"

    /// Ordered list of rules. Order is user-controlled (drag to reorder)
    /// and used as the tie-breaker when two rules have equal-length
    /// `from` strings. Observable so the editor re-renders on any
    /// add/edit/delete/move. Persisted on every mutation via `didSet`.
    private(set) var replacements: [DictationReplacement] {
        didSet { persist() }
    }

    private init() {
        // Restore from UserDefaults. A missing/!corrupt blob starts
        // empty rather than crashing — the table is non-critical and a
        // bad decode shouldn't take down dictation.
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([DictationReplacement].self, from: data) {
            replacements = decoded
        } else {
            replacements = []
        }
    }

    // MARK: - Mutation

    /// Append a blank rule and return its id so the editor can focus the
    /// freshly-added row's first field. Blank rows are harmless —
    /// `apply(to:)` skips any rule whose `from` is empty — so the user
    /// can add a row first and type into it second.
    @discardableResult
    func add() -> UUID {
        let new = DictationReplacement(from: "", to: "")
        replacements.append(new)
        return new.id
    }

    /// Replace a rule in place, matched by `id`. No-op if the id is
    /// unknown (e.g. the row was deleted in another code path between
    /// the editor reading it and committing the edit).
    func update(_ replacement: DictationReplacement) {
        guard let idx = replacements.firstIndex(where: { $0.id == replacement.id }) else { return }
        replacements[idx] = replacement
    }

    /// Remove a rule by value (matched on `id`).
    func remove(_ replacement: DictationReplacement) {
        replacements.removeAll { $0.id == replacement.id }
    }

    /// Reorder rules — thin wrapper over `Array.move` so the editor can
    /// bind `List`/`ForEach` `.onMove` straight to it.
    func move(from source: IndexSet, to destination: Int) {
        replacements.move(fromOffsets: source, toOffset: destination)
    }

    // MARK: - Apply

    /// Run every rule against `text` and return the rewritten string.
    ///
    /// Guarantees:
    ///  - Rules whose `from` is empty (or whitespace-only) are skipped —
    ///    an empty pattern would otherwise match between every character.
    ///  - Matching is anchored to word boundaries (`\b…\b`), so "cat" →
    ///    "dog" leaves "category" untouched. `from` is regex-escaped, so
    ///    a rule like "C++" or "node.js" is matched literally, not as a
    ///    pattern.
    ///  - Case-insensitive unless the rule opts into `caseSensitive`.
    ///  - Longer `from` strings are applied first, so when "daisy" and
    ///    "daisy app" both exist the more specific phrase wins and the
    ///    shorter rule can't eat half of it first.
    ///  - Robust to arbitrary input: any rule whose regex fails to
    ///    compile is skipped rather than aborting the whole pass, and the
    ///    original text is returned unchanged if nothing matches.
    ///
    /// Called on the MainActor from `DictationPaste.handle(transcript:)`.
    func apply(to text: String) -> String {
        guard !text.isEmpty, !replacements.isEmpty else { return text }

        // Apply longest-`from`-first. Stable against the stored order for
        // equal lengths (enumerated index as the tie-breaker) so the
        // user's chosen precedence still decides ties.
        let ordered = replacements
            .enumerated()
            .sorted { lhs, rhs in
                if lhs.element.from.count != rhs.element.from.count {
                    return lhs.element.from.count > rhs.element.from.count
                }
                return lhs.offset < rhs.offset
            }
            .map { $0.element }

        var result = text
        for rule in ordered {
            let needle = rule.from.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty else { continue }
            result = Self.replace(in: result, from: needle, with: rule.to, caseSensitive: rule.caseSensitive)
        }
        return result
    }

    /// Single-rule word-boundary replacement. Factored out (and
    /// `nonisolated static`) so it's trivially unit-testable and carries
    /// no actor or instance state.
    ///
    /// `\b` in ICU is a Unicode word boundary — it sits between a
    /// word-character (`\w`) and a non-word-character. For an alphabetic
    /// `from` this is exactly "whole word". For a `from` that starts or
    /// ends with a non-word character (e.g. "++" or a leading symbol) a
    /// `\b` on that side would never match the way the user expects, so
    /// we drop the boundary on whichever side is non-word and keep it on
    /// the word side. That makes symbol-y rules behave like a literal
    /// substring replace while alphanumeric rules stay whole-word.
    nonisolated static func replace(
        in text: String,
        from: String,
        with replacement: String,
        caseSensitive: Bool
    ) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: from)
        // Only assert a boundary on a side that ends in a word character;
        // a `\b` adjacent to punctuation/symbol would never fire.
        let leadingBoundary = (from.first.map(Self.isWordCharacter) ?? false) ? "\\b" : ""
        let trailingBoundary = (from.last.map(Self.isWordCharacter) ?? false) ? "\\b" : ""
        let pattern = leadingBoundary + escaped + trailingBoundary

        var options: NSRegularExpression.Options = []
        if !caseSensitive { options.insert(.caseInsensitive) }

        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            // Shouldn't happen (the user content is escaped), but if some
            // pathological input slips through, leave the text untouched
            // rather than throwing on the paste path.
            return text
        }

        let range = NSRange(text.startIndex..., in: text)
        // Escape `$`/`\` in the replacement so user text containing them
        // isn't reinterpreted as a capture-group template by the regex
        // engine (e.g. a rule producing "$5" or a Windows path).
        let template = NSRegularExpression.escapedTemplate(for: replacement)
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: template
        )
    }

    /// True when `c` is a Unicode word character (letter, digit, or
    /// underscore) — i.e. a character `\w`/`\b` treats as part of a word.
    private nonisolated static func isWordCharacter(_ c: Character) -> Bool {
        for scalar in c.unicodeScalars {
            if !(CharacterSet.alphanumerics.contains(scalar) || scalar == "_") {
                return false
            }
        }
        return !c.unicodeScalars.isEmpty
    }

    // MARK: - Persistence

    private func persist() {
        do {
            let data = try JSONEncoder().encode(replacements)
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        } catch {
            log.error("Couldn't persist dictation dictionary: \(error.localizedDescription, privacy: .public)")
        }
    }
}
