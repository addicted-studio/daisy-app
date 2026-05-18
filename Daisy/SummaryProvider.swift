//
//  SummaryProvider.swift
//  Daisy
//
//  Abstraction over different summarization back-ends. Daisy ships three:
//
//    • AppleIntelligenceSummarizer — default, 100% on-device via Apple
//      FoundationModels. Best for privacy. Limited to en/es/fr/de/it/pt/ja/ko/zh.
//    • AnthropicAPISummarizer — user provides API key. Strong multilingual
//      (including RU/PL/UA), best quality on hard meetings.
//    • OpenAIAPISummarizer — user provides API key. Multilingual.
//
//  The user picks one in Settings → Summary Provider. Transcript +
//  metadata leaves the Mac only if a non-local provider is selected, and
//  only to the explicitly-configured endpoint.
//

import Foundation

/// What kind of LLM is producing the summary. Persisted as a raw String
/// in UserDefaults; API tokens for the cloud providers live in Keychain.
enum SummaryProviderKind: String, Codable, CaseIterable, Sendable {
    case appleIntelligence
    case anthropic
    case openai
    /// Talks to a user-configured local MCP server that wraps a
    /// local LLM (Ollama / llama.cpp / LM Studio via an MCP shim).
    /// Closes the language gap Apple Intelligence leaves around RU,
    /// UA, PL and friends without any data leaving the Mac.
    case mcp

    var displayName: String {
        switch self {
        case .appleIntelligence: return "Apple Intelligence (on-device)"
        case .anthropic: return "Anthropic Claude API"
        case .openai: return "OpenAI GPT API"
        case .mcp: return "Local LLM via MCP"
        }
    }

    var shortName: String {
        switch self {
        case .appleIntelligence: return "Apple Intelligence"
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        case .mcp: return "MCP"
        }
    }

    var isLocal: Bool {
        self == .appleIntelligence || self == .mcp
    }

    var requiresAPIKey: Bool {
        self == .anthropic || self == .openai
    }

    /// Six-words-ish, parallel structure so users can compare
    /// providers at a glance: `"<destination> — <data flow>."`
    var privacyTag: String {
        switch self {
        case .appleIntelligence:
            return "On-device — nothing is sent anywhere."
        case .anthropic:
            return "Sent to Anthropic over HTTPS, using your API key."
        case .openai:
            return "Sent to OpenAI over HTTPS, using your API key."
        case .mcp:
            return "Sent to your MCP server — stays local if it's on 127.0.0.1."
        }
    }
}

/// Common interface every back-end must satisfy.
protocol SummaryProvider: Sendable {
    var kind: SummaryProviderKind { get }

    /// Quick "is this provider usable right now?" check. For Apple
    /// Intelligence — model availability. For cloud — non-empty API key.
    func isReady() async -> Bool

    /// Produce a structured meeting summary. `localeHint` is a 2-letter
    /// ISO code ("ru", "en", …) used to prompt the model to respond in
    /// the transcript's language.
    func summarize(
        transcript: String,
        title: String,
        localeHint: String?
    ) async throws -> MeetingSummary
}

// MARK: - Provider-level errors

enum SummaryProviderError: LocalizedError {
    case missingAPIKey(provider: String)
    case invalidResponse(provider: String)
    case httpError(provider: String, status: Int, body: String)
    case parseFailed(provider: String, message: String)
    case modelUnavailable(provider: String, reason: String)
    case transcriptTooShort

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let p):
            return "\(p): API key is missing. Open Settings → Summary Provider to add it."
        case .invalidResponse(let p):
            return "\(p): unexpected response from the API."
        case .httpError(let p, let code, let body):
            // Trim very long bodies for the user-visible message.
            let trimmed = body.count > 200 ? String(body.prefix(200)) + "…" : body
            return "\(p): HTTP \(code) — \(trimmed)"
        case .parseFailed(let p, let msg):
            return "\(p): couldn't parse JSON — \(msg)"
        case .modelUnavailable(let p, let reason):
            return "\(p): \(reason)"
        case .transcriptTooShort:
            return "Not enough was said yet — try a recording over a minute long."
        }
    }
}

// MARK: - Shared prompt

enum SummaryPrompt {
    static func systemInstructions(localeHint: String?) -> String {
        let lang: String
        switch localeHint {
        case "ru": lang = "Russian"
        case "uk": lang = "Ukrainian"
        case "pl": lang = "Polish"
        case "es": lang = "Spanish"
        case "fr": lang = "French"
        case "de": lang = "German"
        case "it": lang = "Italian"
        case "pt": lang = "Portuguese"
        case "ja": lang = "Japanese"
        case "ko": lang = "Korean"
        case "zh": lang = "Chinese"
        default:   lang = "the transcript's language (English if mixed)"
        }
        return """
        You summarize meeting transcripts for a busy founder. The
        transcript may contain partial sentences, repetitions, and
        disfluencies — clean them up. Be concise and concrete. Never
        invent details that aren't in the transcript.

        Respond ONLY with valid JSON, no Markdown fences, no prose
        before or after. The JSON must match this exact schema:

        {
          "summary": "2-4 sentence overview of what the meeting was about and what was discussed",
          "actionItems": ["Imperative next step the participants will take after the call, e.g. 'Send invoice to client'", "..."],
          "clientFollowUp": "Ready-to-send follow-up message a client or partner could receive. Second person, polite-professional, 80-180 words, no greeting boilerplate beyond one short opener. Empty string if the meeting had no external counterpart."
        }

        Empty arrays and empty strings are acceptable. Write all text in \(lang).
        """
    }

    static func userPrompt(title: String, transcript: String) -> String {
        """
        Meeting title: \(title)

        Transcript:
        \(transcript)
        """
    }
}

// MARK: - JSON DTO that all cloud providers parse into

/// Cloud providers respond as JSON text; this DTO is decoded from that
/// text and then mapped into the canonical `MeetingSummary` struct.
/// Marked `nonisolated` (along with its extension below) so the
/// `nonisolated` providers — Anthropic, OpenAI, MCP — can decode
/// without an actor hop. The struct holds only Sendable scalars,
/// so cross-actor use is safe.
nonisolated struct CloudSummaryDTO: Codable {
    let summary: String
    let actionItems: [String]?
    let clientFollowUp: String?

    func toMeetingSummary() -> MeetingSummary {
        MeetingSummary(
            summary: summary,
            actionItems: actionItems ?? [],
            clientFollowUp: clientFollowUp ?? ""
        )
    }
}

nonisolated extension CloudSummaryDTO {
    /// Tolerant decoder: many models wrap JSON in ```json … ``` fences
    /// despite the prompt asking them not to. Strip those before decode.
    static func decode(from text: String) throws -> CloudSummaryDTO {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            if let firstNL = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: firstNL)...])
            }
            if s.hasSuffix("```") {
                s = String(s.dropLast(3))
            }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Sometimes the model emits trailing prose after the JSON object.
        // Find the outermost { … } and decode that.
        if let openIdx = s.firstIndex(of: "{"),
           let closeIdx = s.lastIndex(of: "}"),
           openIdx < closeIdx {
            s = String(s[openIdx...closeIdx])
        }
        guard let data = s.data(using: .utf8) else {
            throw SummaryProviderError.parseFailed(
                provider: "cloud",
                message: "Couldn't encode response as UTF-8"
            )
        }
        let decoder = JSONDecoder()
        return try decoder.decode(CloudSummaryDTO.self, from: data)
    }
}
