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
        You summarize meeting transcripts for a busy founder. Transcripts
        may contain partial sentences, repetitions, and disfluencies —
        clean these up. Be concise and concrete. Never invent information
        that isn't in the transcript. The transcript may be in English or
        another language — write the summary in the same language as the
        transcript.
        """

        let session = LanguageModelSession(instructions: instructions)
        session.prewarm()

        let prompt = """
        Meeting title: \(title)

        Transcript:
        \(trimmed)
        """

        do {
            let response = try await session.respond(
                to: prompt,
                generating: MeetingSummary.self
            )
            return response.content
        } catch {
            log.error("AppleIntelligence summarize failed: \(error.localizedDescription, privacy: .public)")
            // Surface Apple's "unsupported language" specifically so the
            // coordinator can offer the user to switch providers.
            let msg = error.localizedDescription
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

    private static func describeReason<R>(_ reason: R) -> String {
        let mirror = String(describing: reason)
        switch mirror {
        case "deviceNotEligible":
            return "This Mac doesn't support Apple Intelligence."
        case "appleIntelligenceNotEnabled":
            return "Turn on Apple Intelligence in System Settings → Apple Intelligence & Siri."
        case "modelNotReady":
            return "Apple Intelligence is still downloading. Try again in a few minutes."
        default:
            return "Not available (\(mirror))."
        }
    }
}
