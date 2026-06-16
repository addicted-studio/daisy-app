//
//  AppleIntelligenceSummarizer.swift
//  Daisy
//
//  SummaryProvider backed by Apple's FoundationModels framework — the
//  on-device LLM that ships with Apple Intelligence on macOS 26+.
//  Nothing leaves the user's Mac.
//

import Foundation
import FoundationModels
import os

// FoundationModels framework + its `@Generable` / `@Guide` macros
// only exist from macOS 26.0 onward (Tahoe — when Apple
// Intelligence's on-device LLM shipped with a public Swift API).
// Gate the whole file so the rest of Daisy can target macOS 14+
// while still lighting up Apple Intelligence on Tahoe.

/// Generable shadow of a single bullet inside an outline section.
/// Apple Intelligence's `@Generable` macro can't introspect a
/// recursive shape (the canonical `SummaryBullet` carries
/// `children: [SummaryBullet]`), so we encode sub-bullets in the
/// string itself: a top-level bullet is just text; a sub-bullet is
/// prefixed with two spaces and a `>` so the parent/child shape
/// survives the round-trip from `String` → `SummaryBullet` tree.
///
/// Example output the model is asked to produce:
///   "Через 1.5 недели: крупный клиент, 5000 исследований/месяц"
///   "  > Сроки: первый платёж до 5 дней"
///   "Цель: 3 клиента по 5000 исследований"
///
/// `toMeetingSummary()` walks the flat list, accumulates `>`
/// children under the most recent top-level bullet. Cloud providers
/// (Anthropic/OpenAI/MCP) still emit the full 2-level nested tree
/// via JSON natively — the workaround is Apple-Intelligence-only.
@available(macOS 26.0, *)
@Generable
private struct GenerableSummarySection: Sendable {
    @Guide(description: "Concise section header in sentence case, 2-6 words. Groups related facts together. Examples: 'Pricing model', 'Doctor onboarding', 'Next steps', 'Технические условия'.")
    let title: String

    @Guide(description: "2-6 short bullets — fragments are fine, no full sentences. Each bullet is a fact, decision, number, name, or commitment from the meeting. 5-18 words per bullet. To add a sub-bullet under the previous top-level bullet, prefix it with TWO SPACES then '>' then a space, like this: '  > supporting detail with a specific number, name, or date'. Max 3 sub-bullets per parent. Most bullets stay flat — only nest when the parent has 2+ concrete supporting facts.")
    let bullets: [String]
}

/// Local Generable mirror of `MeetingSummary`. We don't put
/// `@Generable` on the canonical `MeetingSummary` itself because
/// that macro emits code referencing FoundationModels symbols —
/// which would crash compilation on macOS-14 builds. Keeping the
/// macro confined to this file means `MeetingSummary` stays a
/// plain Codable type that every provider can produce.
///
/// Field-for-field identical to `MeetingSummary` with the `@Guide`
/// descriptions the AI uses to populate each slot. Convert via
/// `.toMeetingSummary()` before handing back to the rest of the app.
@available(macOS 26.0, *)
@Generable
private struct GenerableMeetingSummary: Sendable {
    @Guide(description: "ONE sentence (max 20 words) — what the meeting was about. Topic + the parties involved. Reads as a lede over the topical sections below.")
    let summary: String

    @Guide(description: "Granola-style topical outline of the meeting — 3-5 sections, ordered by importance (decision-heavy first, 'Next steps' last). Each section groups related facts under a short header with a flat bullet list. Empty array ONLY if the transcript is so short (<30 s substantive content) that an outline would be padding — in that case put the gist in the summary field and skip sections.")
    let sections: [GenerableSummarySection]

    @Guide(description: "Block of next actions agreed on during the meeting — what the participants will do after the call ends. Each item in imperative form, e.g. 'Send invoice to client' or 'Review the proposal'. Include the responsible person if explicitly mentioned: 'Maria: send the contract by Thursday'. Empty array if no clear actions were discussed.")
    let actionItems: [String]

    @Guide(description: "Ready-to-send follow-up message that a client or partner from this meeting could receive. Write in the second person, polite-professional tone, no greeting boilerplate beyond a single short opener. Recap what was discussed and what the next steps are. 80-180 words. Empty string ONLY for purely internal team meetings (no external counterpart). A customer call, vendor pitch, partner alignment, or contractor onboarding always counts as external and MUST get a draft.")
    let clientFollowUp: String

    func toMeetingSummary() -> MeetingSummary {
        MeetingSummary(
            summary: summary,
            sections: sections.map { section in
                SummarySection(
                    title: section.title,
                    bullets: Self.parseBullets(section.bullets)
                )
            },
            actionItems: actionItems,
            clientFollowUp: clientFollowUp
        )
    }

    /// Walk a flat `[String]` produced by the Generable model and
    /// reassemble parent/child SummaryBullet tree by detecting the
    /// `  > ` prefix the prompt asks the model to emit. Lines that
    /// start with two spaces and a `>` become children of the most
    /// recent top-level bullet; anything else is a new top-level.
    /// Empty / whitespace-only entries are dropped.
    ///
    /// Robust to leading whitespace variations (3 spaces, tab, etc.)
    /// — any line starting with `>` after stripping leading
    /// whitespace counts as a sub-bullet. A `>` with no recent
    /// parent gets promoted to a top-level bullet (rather than lost).
    nonisolated static func parseBullets(_ raw: [String]) -> [SummaryBullet] {
        var top: [SummaryBullet] = []
        for line in raw {
            let trimmedLeading = line.drop(while: { $0 == " " || $0 == "\t" })
            let isChild = trimmedLeading.hasPrefix(">")
            let text: String
            if isChild {
                text = String(trimmedLeading.dropFirst())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                text = String(trimmedLeading).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !text.isEmpty else { continue }

            if isChild, var lastTop = top.last {
                var children = lastTop.children
                children.append(SummaryBullet(text: text, children: []))
                lastTop = SummaryBullet(text: lastTop.text, children: children)
                top[top.count - 1] = lastTop
            } else {
                top.append(SummaryBullet(text: text, children: []))
            }
        }
        return top
    }
}

@available(macOS 26.0, *)
@MainActor
final class AppleIntelligenceSummarizer: SummaryProvider {
    let kind: SummaryProviderKind = .appleIntelligence

    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "AppleIntelSummarizer")

    nonisolated init() {}

    func isReady() async -> Bool {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available: return true
        case .unavailable: return false
        @unknown default: return false
        }
    }

    func summarize(
        transcript: String,
        title: String,
        localeHint: String?
    ) async throws -> MeetingSummary {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 40 else {
            throw SummaryProviderError.transcriptTooShort
        }

        // Apple Intelligence availability check.
        switch SystemLanguageModel.default.availability {
        case .available: break
        case .unavailable(let reason):
            throw SummaryProviderError.modelUnavailable(
                provider: "Apple Intelligence",
                reason: Self.describeReason(reason)
            )
        @unknown default:
            throw SummaryProviderError.modelUnavailable(
                provider: "Apple Intelligence",
                reason: "Not available"
            )
        }

        let instructions = """
        You write structured notes from meeting transcripts for a busy
        founder. The transcript may contain partial sentences,
        repetitions, and disfluencies — clean them up. Be concise and
        concrete. Never invent details that aren't in the transcript.

        Output a topical OUTLINE, not a paragraph. Short bullets —
        fragments are fine, full sentences are not.

        Constraints:
          - One-sentence summary (≤ 20 words) — the lede.
          - 3-5 sections in the outline, ordered by importance.
            Decision-heavy material first.
          - 2-6 flat bullets per section. If a fact has a supporting
            detail (date / amount / owner), inline it with em-dashes
            or commas instead of a separate bullet.
          - DO NOT include a "Next steps" / "Следующие шаги" /
            equivalent section in the outline. Those commitments
            belong ONLY in actionItems. Outline describes what was
            DISCUSSED; actionItems captures what comes NEXT.
          - actionItems is a flat checklist of imperative next steps.
            If the transcript identifies an owner ("I'll send the X",
            "Margarita принимает решение"), prefix with the name and
            a colon: "Margarita: send the contract by Thursday".
          - clientFollowUp is a ready-to-send message for the external
            counterpart. Empty string ONLY for purely internal team
            syncs. When in doubt, draft one.

        Write everything in the same language as the transcript
        (Russian transcript → Russian summary). The transcript may be
        in English or another language.
        """

        let session = LanguageModelSession(instructions: instructions)
        session.prewarm()

        let prompt = """
        Meeting title: \(title)

        Transcript:
        \(trimmed)
        """

        do {
            // Generate into the local Generable shadow (carries the
            // @Guide field descriptions) — convert to the canonical
            // MeetingSummary on the way out so callers stay
            // FoundationModels-agnostic.
            let response = try await session.respond(
                to: prompt,
                generating: GenerableMeetingSummary.self
            )
            return response.content.toMeetingSummary()
        } catch {
            log.error("AppleIntelligence summarize failed: \(error.localizedDescription, privacy: .public)")
            // Surface Apple's "unsupported language" specifically so the
            // coordinator can offer the user to switch providers.
            let msg = error.localizedDescription
            // Long meeting overflowed the on-device model's small context
            // window → tell the user to switch to a big-context provider.
            // The coordinator turns `modelUnavailable` into a "switch
            // provider" prompt (same path as the language case below).
            if msg.localizedCaseInsensitiveContains("context size") ||
               msg.localizedCaseInsensitiveContains("context window") ||
               msg.localizedCaseInsensitiveContains("exceeded") {
                throw SummaryProviderError.modelUnavailable(
                    provider: "Apple Intelligence",
                    reason: "This recording is too long for Apple Intelligence's on-device model. For long meetings, switch to Anthropic, OpenAI, or Ollama in Settings → Summary."
                )
            }
            if msg.localizedCaseInsensitiveContains("unsupported language") ||
               msg.localizedCaseInsensitiveContains("locale") {
                throw SummaryProviderError.modelUnavailable(
                    provider: "Apple Intelligence",
                    reason: "Apple Intelligence doesn't support this language yet. Switch to Anthropic or OpenAI in Settings."
                )
            }
            throw error
        }
    }

    // MARK: - Helpers

    /// The specific reason Apple Intelligence is unavailable right now, or
    /// `nil` when it's ready. Lets Settings show an actionable message
    /// ("turn it on" / "still downloading" / "this Mac can't") instead of
    /// a bare "Unavailable" badge.
    static func currentUnavailabilityReason() -> String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(let reason): return describeReason(reason)
        @unknown default: return "Not available."
        }
    }

    private static func describeReason<R>(_ reason: R) -> String {
        let mirror = String(describing: reason)
        switch mirror {
        case "deviceNotEligible":
            return "This Mac doesn't support Apple Intelligence."
        case "appleIntelligenceNotEnabled":
            return "Turn on Apple Intelligence in System Settings → Apple Intelligence & Siri — and make sure your Mac and Siri are set to the same supported language (a US vs. UK English mismatch is a common blocker)."
        case "modelNotReady":
            return "Apple Intelligence is still downloading. Try again in a few minutes."
        default:
            return "Not available (\(mirror))."
        }
    }
}
