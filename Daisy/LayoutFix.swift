//
//  LayoutFix.swift
//  Daisy
//
//  Decides WHETHER a piece of text was typed in the wrong keyboard
//  layout, and into which layout it should have gone. The conversion
//  itself is exact (see KeyboardLayout); everything hard lives here,
//  because "чуфе" and "asdf" are both гибберish and only one of them is
//  a mistake.
//
//  Two modes with deliberately different standards of proof:
//
//   - `deliberate` — the user pressed the fix key. They have asserted
//     the text is wrong, so we convert and get out of the way. Refusing
//     because no dictionary recognises either side would be maddening
//     precisely when it matters (passwords typed into a visible field,
//     product names, slang).
//
//   - `automatic` — nobody asked. The bar has to be high enough that
//     being wrong is rare, because being wrong here means silently
//     rewriting what someone typed. The word must be unknown to the
//     system spell checker in the language it was typed in AND a real
//     word in the language it converts to. Both dictionaries must
//     actually be installed; without them we do nothing rather than
//     guess.
//
//  The spell checker is `NSSpellChecker`, i.e. the dictionaries the user
//  already has for the languages they already type in. No word list of
//  ours to ship, stale or bias.
//

import AppKit

@MainActor
enum LayoutFix {

    nonisolated struct Fix: Sendable {
        let text: String
        /// The layout the text should have been typed with — the caller
        /// may switch to it so the NEXT word lands right.
        let target: KeyboardLayout
    }

    /// Shortest word we will touch automatically. Two-letter words are
    /// «по» / «on» / «то» — real in one language and plausible junk in
    /// the other, and a wrong flip on a two-letter word is as annoying
    /// as the mistake it fixes.
    /// `nonisolated`: the event tap reads it from its own callback.
    nonisolated static let minAutomaticWordLength = 3

    // MARK: - Deliberate (the user asked)

    /// Convert text the user has selected (or just typed) into whichever
    /// installed layout makes it real words. Falls back to converting
    /// out of the ACTIVE layout when no dictionary can judge — that is
    /// the single most likely intent, and the user can press again.
    static func deliberate(_ text: String) -> Fix? {
        let layouts = KeyboardLayouts.shared.installed
        guard layouts.count > 1 else { return nil }

        var fallback: Fix?
        var best: (fix: Fix, score: Double)?
        // Source order matters: the active layout first, because it is
        // what produced the text — unless the user already switched
        // layouts before pressing the key, which is why the others are
        // tried at all.
        for source in orderedSources(layouts) {
            for target in layouts where target.id != source.id {
                guard let converted = source.converting(text, to: target) else { continue }
                let candidate = Fix(text: converted, target: target)
                // Score, don't first-hit: with three layouts installed a
                // single incidental real word ("a") in the wrong
                // conversion would otherwise win.
                let score = realWordRatio(in: converted, language: target.language)
                if score > (best?.score ?? 0) { best = (candidate, score) }
                if fallback == nil { fallback = candidate }
            }
        }
        if let best, best.score > 0.5 { return best.fix }
        // Nothing the dictionaries recognise. The user still asked, so
        // convert out of the ACTIVE layout — the most likely intent — and
        // let them press again if it was the other way round.
        return fallback
    }

    // MARK: - Automatic (nobody asked)

    /// A finished word, judged strictly. Nil means "leave it alone",
    /// which is the answer most of the time and has to stay cheap.
    static func automatic(word: String) -> Fix? {
        guard word.count >= minAutomaticWordLength,
              word.contains(where: { $0.isLetter }) else { return nil }
        let layouts = KeyboardLayouts.shared.installed
        guard layouts.count > 1, let source = KeyboardLayouts.shared.current else { return nil }
        // A word we can't judge in the language it was typed in is a word
        // we don't touch.
        guard let sourceLanguage = checkerLanguage(for: source) else { return nil }
        // Already a real word where it stands → by definition not a
        // layout mistake, however odd it looks to us.
        guard !isSpelled(word, language: sourceLanguage) else { return nil }

        for target in layouts where target.id != source.id {
            guard let language = checkerLanguage(for: target),
                  let converted = source.converting(word, to: target),
                  isSpelled(converted, language: language) else { continue }
            return Fix(text: converted, target: target)
        }
        return nil
    }

    /// Spin the spell-check service up ahead of the first keystroke that
    /// needs it — the first `checkSpelling` launches AppleSpell, and that
    /// is not a cost to pay inside someone's typing.
    static func warmUp() {
        _ = checkerLanguages
        _ = isSpelled("warmup", language: "en")
    }

    // MARK: - Judging

    private static func orderedSources(_ layouts: [KeyboardLayout]) -> [KeyboardLayout] {
        guard let current = KeyboardLayouts.shared.current else { return layouts }
        return [current] + layouts.filter { $0.id != current.id }
    }

    /// Share of the words in `text` the dictionary recognises — 0 when
    /// there is no dictionary for the language, so "can't judge" and
    /// "judged badly" read the same to callers.
    private static func realWordRatio(in text: String, language: String?) -> Double {
        guard let language, let checker = resolvedLanguage(language) else { return 0 }
        let words = text
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { $0.contains(where: { $0.isLetter }) }
        guard !words.isEmpty else { return 0 }
        let known = words.filter { isSpelled($0, language: checker) }.count
        return Double(known) / Double(words.count)
    }

    private static func isSpelled(_ word: String, language: String) -> Bool {
        let range = NSSpellChecker.shared.checkSpelling(
            of: word,
            startingAt: 0,
            language: language,
            wrap: false,
            inSpellDocumentWithTag: 0,
            wordCount: nil
        )
        return range.location == NSNotFound
    }

    private static func checkerLanguage(for layout: KeyboardLayout) -> String? {
        guard let language = layout.language else { return nil }
        return resolvedLanguage(language)
    }

    /// The identifier the SPELL CHECKER knows for a layout's language, or
    /// nil when it knows none.
    ///
    /// Load-bearing, not defensive, and the two sides don't even spell
    /// languages the same way: `kTISPropertyInputSourceLanguages` gives
    /// BCP-47 with hyphens ("pt-PT"), `NSSpellChecker.availableLanguages`
    /// gives underscores ("pt_PT"). Worse, `checkSpelling` with a
    /// language it doesn't know reports every word as correctly spelled —
    /// so a failed match wouldn't weaken the judgement, it would invert
    /// it.
    private static func resolvedLanguage(_ language: String) -> String? {
        let wanted = normalized(language)
        if let exact = checkerLanguages[wanted] { return exact }
        guard let primary = wanted.split(separator: "-").first else { return nil }
        return checkerLanguages[String(primary)]
    }

    private static func normalized(_ language: String) -> String {
        language.lowercased().replacingOccurrences(of: "_", with: "-")
    }

    /// Normalised identifier → the identifier to hand back to
    /// NSSpellChecker. Both the full form and the primary subtag are
    /// keyed, so "ru" finds "ru_RU". Cached: the list only changes when a
    /// dictionary is installed, and this is consulted per typed word.
    private static let checkerLanguages: [String: String] = {
        var out: [String: String] = [:]
        for language in NSSpellChecker.shared.availableLanguages {
            let key = normalized(language)
            out[key] = language
            if let primary = key.split(separator: "-").first, out[String(primary)] == nil {
                out[String(primary)] = language
            }
        }
        return out
    }()
}
