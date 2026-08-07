//
//  SpeakerNameSuggester.swift
//  Daisy
//
//  Who is "Remote B"? Diarization can tell voices apart but cannot
//  name them; voice fingerprints only recognize people the user has
//  already named once. That leaves the common case unsolved — a first
//  meeting with three people from the invite, and a transcript full of
//  "спасибо, Прия" and "Alex, can you take that one?".
//
//  This pass reads the finished transcript alongside the invite's
//  attendee list and proposes label → name. It runs after
//  `TranscriptPolisher`, so the names in the text have already been
//  restored to their canonical spelling and match the invite.
//
//  **Nothing here is ever applied automatically.** Proposals go to the
//  `speaker_suggestions.json` sidecar, where the session's
//  Name-the-speakers card renders each one with a Confirm and a
//  Dismiss. That is a deliberate ceiling on the damage: a wrong name
//  in a transcript is worse than no name at all — it is a quotation
//  attributed to a real person who did not say it, and it propagates
//  into the summary, the follow-up draft, and anything auto-sent.
//  "Remote B" is honest; "Priya" might not be.
//
//  The guard that makes the proposals safe is an allow-list, not a
//  prompt: a suggestion survives only if it resolves to a name from
//  THIS meeting's invite. The model cannot introduce a name, and it
//  cannot move a name in from another meeting — the worst it can do is
//  propose the wrong one of the people who were actually there, which
//  the user then declines with one click.
//

import Foundation
import os

nonisolated enum SpeakerNameSuggester {
    private static let log = Logger(subsystem: "app.essazanov.Daisy", category: "SpeakerNames")

    /// How much transcript the model gets to read. Introductions sit at
    /// the top and hand-offs / goodbyes at the bottom, so the sample is
    /// taken from both ends rather than truncating the tail — the
    /// middle of a meeting is where names are used LEAST (everyone
    /// already knows who's talking).
    static let transcriptSampleBudget = 6_000

    /// One request, so a single ceiling rather than the polish's
    /// per-chunk and total pair.
    static let deadlineSeconds: Double = 25

    // MARK: - Prompt context

    /// Plain `Sendable` scalars for the hop into the `nonisolated`
    /// providers, same contract as `TranscriptPolisher.PromptContext`.
    struct PromptContext: Sendable {
        /// Canonical display names from the invite. Doubles as the
        /// allow-list — a proposal that doesn't resolve to one of these
        /// is discarded.
        let attendees: [String]
        /// Remote diarization labels present in the transcript ("A",
        /// "B", …) that still have no name.
        let labels: [String]
    }

    // MARK: - Entry point

    /// Ask for label → name, and return only what survives the
    /// allow-list. Never throws; every failure returns fewer proposals.
    static func suggest(
        transcript: String,
        context: PromptContext,
        summarize: @escaping @Sendable (String, SummaryTask) async throws -> MeetingSummary
    ) async -> [String: String] {
        guard !context.labels.isEmpty, !context.attendees.isEmpty else { return [:] }

        guard let reply = await TranscriptPolisher.withDeadline(seconds: deadlineSeconds, operation: {
            try await summarize(transcript, .speakerNames(context)).clientFollowUp
        }) else {
            log.info("Speaker-name pass failed or timed out — no suggestions")
            return [:]
        }

        let proposed = parseAssignments(reply)
        let accepted = filter(proposed, context: context)
        log.info("Speaker-name pass: \(proposed.count, privacy: .public) proposed, \(accepted.count, privacy: .public) survived the invite allow-list")
        return accepted
    }

    // MARK: - Transcript sampling

    /// Render the remote side of the transcript as `A: text` lines,
    /// sampled from both ends to fit `budget`.
    ///
    /// Mic-side segments are included WITHOUT a label ("—" for the
    /// user's own turns), because the vocative that names someone is
    /// usually spoken BY the user ("thanks, Priya") and the model needs
    /// to see the turn it attaches to. They carry no label of their
    /// own to propose, so there is nothing to confuse.
    static func sampleTranscript(
        _ segments: [TranscriptSegment],
        budget: Int = transcriptSampleBudget
    ) -> String {
        var lines: [String] = []
        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let flat = text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            switch segment.source {
            case .microphone:
                lines.append("—: \(flat)")
            case .systemAudio:
                lines.append("\(segment.speakerId ?? "?"): \(flat)")
            }
        }
        guard !lines.isEmpty else { return "" }

        let total = lines.reduce(0) { $0 + $1.count + 1 }
        guard total > budget else { return lines.joined(separator: "\n") }

        // Head gets the larger share: introductions ("hi, this is
        // Priya") are the single richest source of names in a meeting.
        var head: [String] = []
        var headBudget = budget * 3 / 5
        for line in lines {
            guard headBudget - line.count > 0 else { break }
            head.append(line)
            headBudget -= line.count + 1
        }
        var tail: [String] = []
        var tailBudget = budget - (budget * 3 / 5)
        for line in lines.reversed() {
            guard tailBudget - line.count > 0 else { break }
            tail.append(line)
            tailBudget -= line.count + 1
        }
        // A single utterance longer than the whole budget takes neither
        // loop (both break on the first line), which would return "" and
        // silently skip the pass. One long unbroken segment is a real
        // shape — a short call where VAD never split — so truncate it
        // rather than dropping the meeting.
        if head.isEmpty && tail.isEmpty {
            return String(lines[0].prefix(budget))
        }

        // Overlapping ends on a short-but-over-budget transcript would
        // duplicate lines; trim the tail to what the head didn't take.
        let headCount = head.count
        let tailSlice = tail.reversed().suffix(max(0, lines.count - headCount))
        guard !tailSlice.isEmpty else { return head.joined(separator: "\n") }
        return (head + ["[…]"] + tailSlice).joined(separator: "\n")
    }

    // MARK: - Reply parsing

    /// Parse `A = Priya Raman` lines into `[label: name]`. Unrecognized
    /// lines are ignored rather than failing the parse — unlike the
    /// polish there is no line-for-line contract to protect here, and
    /// the allow-list below is the real guard. `?`, `unknown` and empty
    /// values mean "the model declined", which is a valid answer.
    static func parseAssignments(_ reply: String) -> [String: String] {
        var result: [String: String] = [:]
        // Labels the reply named more than once. A model that answers
        // "A = Priya" and then "A = Alex" has contradicted itself about
        // that speaker; keeping whichever came last would be picking a
        // side at random. The label is dropped — the others in the same
        // reply still stand, since a contradiction about one speaker
        // says nothing about the rest.
        var contradicted: Set<String> = []
        for rawLine in reply.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let separator = line.firstIndex(of: "=") else { continue }
            let label = line[line.startIndex..<separator]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-*• "))
            let name = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            // Labels are the single letters diarization produces. A
            // longer left-hand side is prose that happened to contain
            // an equals sign.
            guard label.count == 1, label.first?.isLetter == true else { continue }
            let key = label.uppercased()
            let lowered = name.lowercased()
            guard !name.isEmpty, name != "?",
                  lowered != "unknown", lowered != "неизвестно" else { continue }
            if result[key] != nil, result[key] != name { contradicted.insert(key) }
            result[key] = name
        }
        for key in contradicted { result.removeValue(forKey: key) }
        return result
    }

    // MARK: - Allow-list

    /// Keep only proposals that name a real attendee of this meeting,
    /// for a label that actually needs one, uniquely.
    static func filter(_ proposed: [String: String], context: PromptContext) -> [String: String] {
        let labels = Set(context.labels)
        var byLabel: [String: String] = [:]
        for (label, raw) in proposed {
            guard labels.contains(label) else { continue }
            guard let canonical = canonicalName(raw, in: context.attendees) else {
                log.info("Dropped a proposed name that isn't on this invite")
                continue
            }
            byLabel[label] = canonical
        }

        // One name, one voice. If the model put the same person behind
        // two labels it was guessing at least once, and we have no way
        // to tell which — so neither is offered.
        var owners: [String: [String]] = [:]
        for (label, name) in byLabel { owners[name, default: []].append(label) }
        for (name, labels) in owners where labels.count > 1 {
            log.info("Dropped \(labels.count, privacy: .public) proposals that named the same attendee")
            for label in labels { byLabel.removeValue(forKey: label) }
            _ = name
        }
        return byLabel
    }

    /// Resolve a proposed name to the invite's spelling, or nil if it
    /// isn't on the invite.
    ///
    /// Exact normalized match first. Failing that, a single given name
    /// ("Priya") resolves to a full attendee name it begins ("Priya
    /// Raman") — people say first names in meetings, and dropping those
    /// would discard most of what this pass is for. Ambiguity is fatal:
    /// two attendees named Priya means neither is offered.
    static func canonicalName(_ raw: String, in attendees: [String]) -> String? {
        guard let needle = SpeakerProfileStore.normalizeName(raw) else { return nil }
        for attendee in attendees where SpeakerProfileStore.normalizeName(attendee) == needle {
            return attendee
        }
        // A multi-word proposal that didn't match exactly is not a bare
        // given name — treating it as a prefix would let "Priya Raman
        // from Acme" through as "Priya Raman".
        guard !needle.contains(" ") else { return nil }
        let matches = attendees.filter { attendee in
            guard let normalized = SpeakerProfileStore.normalizeName(attendee) else { return false }
            return normalized == needle || normalized.hasPrefix(needle + " ")
        }
        return matches.count == 1 ? matches[0] : nil
    }
}
