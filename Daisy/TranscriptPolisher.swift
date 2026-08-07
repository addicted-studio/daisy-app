//
//  TranscriptPolisher.swift
//  Daisy
//
//  Second LLM pass over a FINISHED transcript — the text-layer
//  counterpart to the final Whisper pass (which is the ASR layer).
//  Whisper hears "фигма", "Прия", "эй-пи-ай"; a model that knows who
//  was on the invite and what's in the user's vocabulary writes
//  "Figma", "Priya", "API". Nothing else is allowed to change.
//
//  Runs on the user's OWN summary provider (Apple Intelligence /
//  Ollama / LM Studio locally, or their own API key), so "everything
//  stays on this Mac" survives the feature — the pass is only offered
//  when the transcript was already going to that provider anyway.
//
//  Three properties make this safe to run unattended:
//
//    1. **It never sees structure.** The model is handed numbered
//       utterance TEXT and nothing else — no `## Transcript` heading,
//       no `**[00:12 · Remote A]**` prefixes, no frontmatter. Speaker
//       labels and timings are re-rendered from the untouched segment
//       metadata afterwards, so there is no prompt in the world that
//       can corrupt them.
//    2. **Every chunk is checked before it is believed.** The reply
//       must return every line, same count, same numbers, with nothing
//       trailing it; each line must stay within a tight length band and
//       change no more than half its own word tokens; and the chunk as
//       a whole gets a 15% token budget, counting insertions as dearly
//       as deletions. A chunk that fails any of these is dropped whole
//       and the original text stands. So: paraphrase, condensation,
//       invented clauses, swapped lines, and the model's own sign-off
//       all end the same way — with the transcript unchanged.
//    3. **The raw transcript survives on disk** as `transcript.raw.md`,
//       so the polish is a re-creatable layer rather than a
//       destructive edit.
//
//  Degradation is silent by design: a provider timeout, a refusal, a
//  malformed reply, or a blown deadline all end with the un-polished
//  transcript and a line in os_log. The user is mid-close-the-laptop;
//  there is nothing here worth a toast.
//

import Foundation
import os

nonisolated enum TranscriptPolisher {
    private static let log = Logger(subsystem: "app.essazanov.Daisy", category: "TranscriptPolisher")

    // MARK: - Tunables

    /// Target size of one request, in characters of utterance text.
    /// Chunk boundaries always fall between segments.
    ///
    /// The binding constraint is the reply, not the prompt: this task
    /// asks the model to echo every line BACK, and every provider caps
    /// output at 4096 tokens (`AnthropicAPISummarizer`, `OpenAI…`,
    /// `Ollama…`, `LMStudio…`, `Kimi…` all agree on that number). A
    /// truncated reply loses lines, fails the count contract, and the
    /// chunk is dropped — so an over-large budget doesn't degrade the
    /// polish, it silently deletes it. Russian is the worst case at
    /// roughly a token per character; 2500 keeps even that comfortably
    /// under the ceiling with the line numbers and JSON envelope on top.
    static let chunkCharacterBudget = 2_500

    /// A trailing chunk shorter than this is folded back into the
    /// previous one. Every provider rejects a payload under 40
    /// characters with `transcriptTooShort`, so a lone short utterance
    /// at the end would burn a request to produce a guaranteed failure.
    static let minTrailingChunkCharacters = 60

    /// Per-chunk ceiling. Bounds a single hung request so one bad chunk
    /// can't eat the whole budget.
    static let chunkDeadlineSeconds: Double = 25

    /// Floor and ceiling for the whole-pass deadline the caller derives
    /// from how long the final Whisper pass took (see
    /// `RecordingSession.runTranscriptPolish`). Once the deadline
    /// elapses, remaining chunks are skipped and whatever was already
    /// polished is kept — every chunk is validated independently, so a
    /// partial pass is not a broken one.
    static let minTotalDeadlineSeconds: Double = 20
    static let maxTotalDeadlineSeconds: Double = 120

    /// Share of a chunk's word tokens the model may change before we
    /// stop believing it. Name and brand corrections are a small
    /// fraction of any real utterance; a chunk where one word in six
    /// moved is a model that started paraphrasing, and paraphrase is
    /// exactly what this pass must never ship. Learned from the
    /// Apple-Intelligence × TaskLocal bug, where a polish pass quietly
    /// replaced the user's dictation with an invented letter.
    static let maxChangedTokenRatio = 0.15

    /// Same idea, per line, for lines long enough for the ratio to mean
    /// something. The chunk-wide budget alone is too coarse to notice a
    /// single line being replaced wholesale — two utterances swapping
    /// text costs only a few percent of a whole chunk, and would leave
    /// one speaker saying another's words under their own timestamp.
    static let maxChangedTokenRatioPerLine = 0.5
    static let perLineRatioMinimumTokens = 4

    // MARK: - Prompt context

    /// What the model gets to know about the meeting besides the words.
    /// All plain `Sendable` scalars so it threads across the actor hops
    /// into the `nonisolated` providers — same contract as
    /// `SummaryPrompt.BriefPromptInfo`.
    struct PromptContext: Sendable {
        /// Display names from the calendar invite. The single highest-
        /// value signal: these are the proper nouns most likely to be
        /// mangled and the ones a user notices immediately.
        let attendees: [String]
        /// Terms from the user's dictation vocabulary — their jargon,
        /// product names, and internal acronyms.
        let vocabulary: [String]
        /// "Zoom", "Google Meet", … — weak context that helps the model
        /// read platform chatter ("you're on mute") as speech rather
        /// than something to fix.
        let meetingApp: String?

        var isEmpty: Bool {
            attendees.isEmpty && vocabulary.isEmpty && (meetingApp?.isEmpty ?? true)
        }
    }

    // MARK: - Result

    struct Outcome: Sendable {
        /// New text keyed by segment id. Only segments the pass actually
        /// changed appear — callers apply this as a patch.
        let replacements: [UUID: String]
        let chunksTotal: Int
        let chunksApplied: Int
        /// True when the total deadline cut the pass short.
        let timedOut: Bool

        static let empty = Outcome(replacements: [:], chunksTotal: 0, chunksApplied: 0, timedOut: false)
    }

    // MARK: - Entry point

    /// Polish `segments` and return the text replacements to apply.
    ///
    /// Pure in the sense that matters: it mutates nothing, writes
    /// nothing, and reads no shared state — the caller owns applying
    /// the patch and saving the raw copy. Never throws; every failure
    /// path returns fewer replacements.
    ///
    /// `segments` should be the FINAL-quality set (post final-Whisper,
    /// post-diarization). Empty and whitespace-only segments are
    /// skipped rather than sent — they carry no proper nouns and would
    /// only waste context.
    static func polish(
        segments: [TranscriptSegment],
        context: PromptContext,
        localeHint: String?,
        deadlineSeconds: Double,
        summarize: @escaping @Sendable (String, SummaryTask) async throws -> MeetingSummary
    ) async -> Outcome {
        let candidates = segments.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !candidates.isEmpty else { return .empty }

        let chunks = makeChunks(candidates)
        guard !chunks.isEmpty else { return .empty }

        let budget = min(max(deadlineSeconds, minTotalDeadlineSeconds), maxTotalDeadlineSeconds)
        let start = Date()
        var replacements: [UUID: String] = [:]
        var applied = 0
        var timedOut = false

        for (index, chunk) in chunks.enumerated() {
            // The caller's own rotation guard runs after this returns,
            // but a provider that ignores cancellation would otherwise
            // keep shipping the OLD session's transcript while the user
            // is already recording the next meeting.
            if Task.isCancelled {
                log.info("Polish cancelled after \(index, privacy: .public)/\(chunks.count, privacy: .public) chunks")
                break
            }
            let spent = Date().timeIntervalSince(start)
            let left = budget - spent
            // Don't start a chunk we can't plausibly finish — a request
            // issued with 2 seconds left is a guaranteed discard that
            // still costs tokens.
            guard left > 5 else {
                timedOut = true
                log.warning("Polish deadline reached after \(index, privacy: .public)/\(chunks.count, privacy: .public) chunks — keeping the rest un-polished")
                break
            }

            let deadline = min(chunkDeadlineSeconds, left)
            guard let reply = await withDeadline(seconds: deadline, operation: {
                try await summarize(
                    SummaryPrompt.transcriptPolishPayload(lines: chunk.lines),
                    .transcriptPolish(context)
                ).clientFollowUp
            }) else {
                log.warning("Polish chunk \(index, privacy: .public) failed or timed out — chunk kept as-is")
                continue
            }

            guard let accepted = validate(reply: reply, chunk: chunk) else {
                continue
            }
            for (id, text) in accepted { replacements[id] = text }
            applied += 1
        }

        log.info("Polish: \(applied, privacy: .public)/\(chunks.count, privacy: .public) chunks applied, \(replacements.count, privacy: .public) segment(s) rewritten in \(Int(Date().timeIntervalSince(start)), privacy: .public)s")
        return Outcome(
            replacements: replacements,
            chunksTotal: chunks.count,
            chunksApplied: applied,
            timedOut: timedOut
        )
    }

    // MARK: - Chunking

    struct Chunk {
        /// Segment ids in the order they were numbered, 1-based in the
        /// prompt. `ids[0]` is line 1.
        let ids: [UUID]
        /// The exact text sent for each id, trimmed.
        let lines: [String]
    }

    /// Split segments into request-sized runs. Never splits a segment;
    /// an utterance longer than the budget gets a chunk to itself rather
    /// than being cut mid-sentence (cutting would strip the very context
    /// that lets the model recognize a name).
    static func makeChunks(_ segments: [TranscriptSegment]) -> [Chunk] {
        var chunks: [Chunk] = []
        var ids: [UUID] = []
        var lines: [String] = []
        var size = 0

        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if !ids.isEmpty && size + text.count > chunkCharacterBudget {
                chunks.append(Chunk(ids: ids, lines: lines))
                ids = []
                lines = []
                size = 0
            }
            ids.append(segment.id)
            lines.append(text)
            size += text.count
        }
        if !ids.isEmpty {
            chunks.append(Chunk(ids: ids, lines: lines))
        }

        // Fold a too-short tail back into its predecessor rather than
        // spending a request that every provider will refuse outright.
        if chunks.count >= 2,
           let tail = chunks.last,
           tail.lines.reduce(0, { $0 + $1.count }) < minTrailingChunkCharacters {
            let previous = chunks[chunks.count - 2]
            chunks.removeLast(2)
            chunks.append(Chunk(ids: previous.ids + tail.ids, lines: previous.lines + tail.lines))
        }
        return chunks
    }

    // MARK: - Validation

    /// Parse the model's reply and decide whether to believe it.
    /// Returns the accepted replacements (changed lines only), or `nil`
    /// to discard the whole chunk.
    ///
    /// All-or-nothing per chunk on purpose: the failure mode we're
    /// defending against — the model deciding to summarize or
    /// paraphrase — is a property of the whole reply, not of individual
    /// lines. Salvaging "the lines that happen to look fine" out of a
    /// reply that broke its contract is how a paraphrase slips through.
    static func validate(reply: String, chunk: Chunk) -> [UUID: String]? {
        // `1...0` would trap. `makeChunks` never produces an empty
        // chunk, but this is internal and directly unit-tested, so a
        // future caller should get a dropped chunk, not a crash.
        guard !chunk.lines.isEmpty else { return nil }
        guard let parsed = parseNumberedLines(reply) else {
            log.warning("Polish reply unparseable — chunk dropped")
            return nil
        }

        // Contract: exactly the lines we sent, no more, no fewer.
        // A dropped line means the model condensed; an extra means it
        // invented. Either way the 1:1 mapping we rely on is gone.
        guard parsed.count == chunk.lines.count,
              Set(parsed.keys) == Set(1...chunk.lines.count) else {
            log.warning("Polish reply had \(parsed.count, privacy: .public) lines for \(chunk.lines.count, privacy: .public) sent — chunk dropped")
            return nil
        }

        var changedTokens = 0
        var totalTokens = 0
        var result: [UUID: String] = [:]

        for (number, polished) in parsed.sorted(by: { $0.key < $1.key }) {
            let original = chunk.lines[number - 1]
            let trimmed = polished.trimmingCharacters(in: .whitespacesAndNewlines)

            // An emptied line is a deletion, not a correction.
            guard !trimmed.isEmpty else {
                log.warning("Polish emptied a line — chunk dropped")
                return nil
            }

            // Per-line ballpark check. Corrections are local edits:
            // restoring a Latin spelling or adding a comma moves a line
            // by a few characters, not by half its length. The ceiling
            // is deliberately close to the input — a generous one lets a
            // model append an invented clause to every line, which the
            // token budget below would then have to catch alone.
            //
            // Both bounds carry a flat slack term rather than being
            // pure ratios: the floor so a short line can lose length to
            // a legitimate fix ("эй-пи-ай" → "API"), the ceiling so it
            // can gain a comma and a capital. The ceiling's slack is the
            // tighter of the two on purpose — every character of it is
            // room for an invented clause.
            let inCount = original.count
            let outCount = trimmed.count
            guard outCount * 2 + 20 >= inCount,
                  outCount <= inCount * 5 / 4 + 12 else {
                log.warning("Polish line length out of range (\(inCount, privacy: .public) → \(outCount, privacy: .public)) — chunk dropped")
                return nil
            }

            let before = tokenize(original)
            let after = tokenize(trimmed)

            // A line with no word tokens is punctuation, music notation,
            // or Whisper's silence artefact ("...", "♪"). There is
            // nothing in it to correct, and with an empty `before` the
            // token budget below can't charge for anything the model
            // puts there — so it may only stay wordless.
            if before.isEmpty {
                guard after.isEmpty else {
                    log.warning("Polish put words into a wordless line — chunk dropped")
                    return nil
                }
            }

            let lineChanged = changedTokenCount(from: before, to: after)
            if before.count >= perLineRatioMinimumTokens {
                guard Double(lineChanged) <= maxChangedTokenRatioPerLine * Double(before.count) else {
                    log.warning("Polish rewrote a single line (\(lineChanged, privacy: .public)/\(before.count, privacy: .public) tokens) — chunk dropped")
                    return nil
                }
            }
            totalTokens += before.count
            changedTokens += lineChanged

            if trimmed != original {
                result[chunk.ids[number - 1]] = trimmed
            }
        }

        // Chunk-wide diff budget — the main guard.
        if totalTokens > 0 {
            let ratio = Double(changedTokens) / Double(totalTokens)
            guard ratio <= maxChangedTokenRatio else {
                log.warning("Polish changed \(Int(ratio * 100), privacy: .public)% of tokens (limit \(Int(maxChangedTokenRatio * 100), privacy: .public)%) — chunk dropped")
                return nil
            }
        }

        return result
    }

    /// Parse `1. text` / `1) text` numbered output into `[number: text]`.
    ///
    /// Leading prose before the first number is ignored — models like to
    /// open with "Sure, here are the corrected lines:". Unnumbered lines
    /// BETWEEN two numbers are folded onto the earlier one, which is what
    /// a hard-wrapped long utterance looks like.
    ///
    /// Unnumbered text AFTER the last number fails the parse. It has the
    /// same shape as a wrapped final line, but it is also the shape of
    /// "Let me know if you need anything else." and
    /// "Note: corrected Figma from фигма" — and appending those to the
    /// last utterance writes the model's own words into the record as
    /// something a participant said. The trade is deliberate and
    /// one-sided: rejecting a genuinely wrapped final line costs one
    /// chunk's polish, accepting chatter corrupts the transcript.
    ///
    /// A reply with no numbers at all is a parse failure.
    static func parseNumberedLines(_ reply: String) -> [Int: String]? {
        var result: [Int: String] = [:]
        var current: Int? = nil
        // Unnumbered lines seen since the last number. Committed only
        // once ANOTHER number proves they were an interior wrap.
        var pendingContinuation: [String] = []

        for rawLine in reply.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let (number, rest) = splitLeadingNumber(line) {
                if let current, !pendingContinuation.isEmpty {
                    result[current] = ([result[current] ?? ""] + pendingContinuation)
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                    pendingContinuation = []
                }
                // A repeated number means the reply lost its structure —
                // we'd silently keep the last copy otherwise.
                if result[number] != nil { return nil }
                result[number] = rest
                current = number
            } else if current != nil, !line.isEmpty {
                pendingContinuation.append(line)
            }
        }
        guard pendingContinuation.isEmpty else { return nil }
        return result.isEmpty ? nil : result
    }

    /// `"12. Привет"` → `(12, "Привет")`. Nil when the line doesn't open
    /// with `<digits><.|)>`. Bounded at 6 digits so a line that opens
    /// with a year or a long figure isn't mistaken for a marker.
    private static func splitLeadingNumber(_ line: String) -> (Int, String)? {
        var digits = ""
        var index = line.startIndex
        while index < line.endIndex, line[index].isNumber, digits.count < 6 {
            digits.append(line[index])
            index = line.index(after: index)
        }
        guard !digits.isEmpty, index < line.endIndex,
              line[index] == "." || line[index] == ")",
              let number = Int(digits) else { return nil }
        let rest = line[line.index(after: index)...]
        return (number, String(rest).trimmingCharacters(in: .whitespaces))
    }

    // MARK: - Token diffing

    /// Word tokens for the diff budget: letters and digits only,
    /// case-folded. Punctuation is deliberately dropped — fixing
    /// punctuation is part of this pass's remit, so it must not spend
    /// the change budget. Case is folded because "figma" → "Figma"
    /// should be free while "фигма" → "Figma" (a real token change) is
    /// what the budget is counting.
    ///
    /// Scripts that don't put spaces between words (Chinese, Japanese,
    /// Thai, Khmer, Lao, Burmese) are split per character instead.
    /// Whitespace-splitting them yields one "token" per clause, which
    /// breaks the budget in both directions at once: a wholesale rewrite
    /// of a clause costs 1, while an honest one-character name fix also
    /// costs 1 out of very few. Per-character granularity puts those
    /// languages on roughly the same footing as a spaced one.
    static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .flatMap(splitRun)
    }

    /// One whitespace-delimited run → tokens. Characters from unspaced
    /// scripts each become their own token; anything else accumulates
    /// into a word, so a Latin brand embedded in Japanese ("zoomで会議")
    /// still compares as one token rather than four letters.
    private static func splitRun(_ run: Substring) -> [String] {
        guard run.contains(where: isUnspacedScript) else { return [String(run)] }
        var tokens: [String] = []
        var word = ""
        for character in run {
            if isUnspacedScript(character) {
                if !word.isEmpty { tokens.append(word); word = "" }
                tokens.append(String(character))
            } else {
                word.append(character)
            }
        }
        if !word.isEmpty { tokens.append(word) }
        return tokens
    }

    /// True for characters from writing systems with no word separator.
    /// Hangul is intentionally absent — Korean puts spaces between
    /// words, so it tokenizes correctly as-is.
    private static func isUnspacedScript(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first?.value else { return false }
        switch scalar {
        case 0x0E00...0x0EFF,      // Thai, Lao
             0x1000...0x109F,      // Myanmar
             0x1780...0x17FF,      // Khmer
             0x3040...0x30FF,      // Hiragana, Katakana
             0x3400...0x4DBF,      // CJK Unified Ideographs Ext A
             0x4E00...0x9FFF,      // CJK Unified Ideographs
             0xF900...0xFAFF:      // CJK Compatibility Ideographs
            return true
        default:
            return false
        }
    }

    /// Distance between two token multisets, in tokens. Comparing as
    /// multisets means a repeated word isn't matched twice; taking the
    /// larger of the two directions means an INSERTION costs as much as
    /// a deletion.
    ///
    /// That symmetry is the point. Counting only what disappeared makes
    /// pure additions free, and "leave every word alone but append an
    /// invented clause" is both the cheapest way to corrupt a transcript
    /// and a completely natural thing for a helpful model to do —
    /// finishing a trailing-off sentence, appending a translation,
    /// tacking a note onto the end.
    static func changedTokenCount(from before: [String], to after: [String]) -> Int {
        max(unmatchedCount(of: before, against: after),
            unmatchedCount(of: after, against: before))
    }

    /// How many of `tokens` have no partner left in `pool`.
    private static func unmatchedCount(of tokens: [String], against pool: [String]) -> Int {
        var available: [String: Int] = [:]
        for token in pool { available[token, default: 0] += 1 }
        var missing = 0
        for token in tokens {
            if let count = available[token], count > 0 {
                available[token] = count - 1
            } else {
                missing += 1
            }
        }
        return missing
    }

    // MARK: - Deadline

    /// Race `operation` against a sleep. Returns nil when the operation
    /// throws or the deadline wins. Same shape as
    /// `RecordingSession.polishWithDeadline`, minus that one's
    /// dictation-specific length gate — validation here is per chunk.
    private static func withDeadline(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> String
    ) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask {
                try? await operation()
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil  // deadline sentinel
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
