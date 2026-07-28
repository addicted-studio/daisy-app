//
//  AnthropicAPISummarizer.swift
//  Daisy
//
//  SummaryProvider that calls Anthropic's Messages API. User supplies
//  their own API key (stored in Keychain). The transcript is sent only
//  to api.anthropic.com over HTTPS.
//

import Foundation
import os

nonisolated struct AnthropicAPISummarizer: SummaryProvider {
    let kind: SummaryProviderKind = .anthropic

    /// Model identifier. Defaults to Sonnet 5 — strong quality/cost.
    let model: String
    /// Override for testing; production passes URLSession.shared.
    let urlSession: URLSession

    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "AnthropicSummarizer")

    init(model: String = defaultModelID, urlSession: URLSession = .shared) {
        self.model = model
        self.urlSession = urlSession
    }

    func isReady() async -> Bool {
        if let key = KeychainStore.get(account: SecretKey.anthropicAPIKey), !key.isEmpty {
            return true
        }
        return false
    }

    func summarize(
        transcript: String,
        title: String,
        localeHint: String?,
        task: SummaryTask
    ) async throws -> MeetingSummary {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 40 else {
            throw SummaryProviderError.transcriptTooShort
        }
        guard let apiKey = KeychainStore.get(account: SecretKey.anthropicAPIKey),
              !apiKey.isEmpty else {
            throw SummaryProviderError.missingAPIKey(provider: "Anthropic")
        }

        let systemPrompt = SummaryPrompt.systemInstructions(localeHint: localeHint, task: task)
        let userPrompt = SummaryPrompt.userPrompt(title: title, transcript: trimmed, task: task)

        let body: [String: Any] = [
            "model": model,
            // 4096 (was 2048 pre-1.0.3) — long Russian / German / Polish
            // summaries hit the 2048 ceiling on hour-long meetings,
            // truncating the clientFollowUp draft mid-sentence. 4096
            // covers the worst realistic case at ~1.5 hour meetings;
            // cost delta is ~0.5¢ per call at Sonnet list pricing.
            "max_tokens": 4096,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": userPrompt]
            ]
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        // Retry up to 3 attempts on transient failures (429 rate
        // limit, 5xx server errors, network timeouts). Each retry
        // waits 1s → 2s → 4s. Pre-1.0.3 a single network blip
        // killed a 90-second summary call and surfaced as "Anthropic:
        // HTTP 503" with no recovery — user had to manually
        // re-summarize from History.
        let (data, response) = try await CloudHTTPRetry.fetch(
            request: request,
            session: urlSession,
            log: log
        )
        guard let http = response as? HTTPURLResponse else {
            throw SummaryProviderError.invalidResponse(provider: "Anthropic")
        }
        if !(200..<300).contains(http.statusCode) {
            let bodyString = String(data: data, encoding: .utf8) ?? "<empty>"
            // bodyString stays .private — Anthropic 4xx responses can
            // echo prompt fragments back, which would leak transcript
            // snippets into the unified system log. Status code is
            // safe to expose; the body itself is not.
            log.error("Anthropic HTTP \(http.statusCode): \(bodyString, privacy: .private)")
            throw SummaryProviderError.httpError(
                provider: "Anthropic",
                status: http.statusCode,
                body: bodyString
            )
        }

        // Response shape:
        // { "id": "...", "type": "message",
        //   "content": [{ "type": "text", "text": "<JSON we want>" }],
        //   ... }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SummaryProviderError.invalidResponse(provider: "Anthropic")
        }

        // A 2xx response can still contain malformed content. Usage was
        // nevertheless reported by Anthropic, so account for that charge
        // before validating the content Daisy needs to parse.
        TokenLedgerSink.recordAnthropic(model: model, json: json)

        guard let content = json["content"] as? [[String: Any]],
              let firstText = content.first?["text"] as? String else {
            throw SummaryProviderError.invalidResponse(provider: "Anthropic")
        }

        do {
            let dto = try CloudSummaryDTO.decode(from: firstText)
            return dto.toMeetingSummary()
        } catch {
            throw SummaryProviderError.parseFailed(
                provider: "Anthropic",
                message: error.localizedDescription
            )
        }
    }

    // MARK: - Catalog of model IDs offered in Settings

    /// Refreshed 2026-07-28. Four rungs, cheapest-capable first:
    /// Sonnet is the one to use, Opus when the meeting is dense, Fable
    /// when nothing else will do, Haiku when volume matters more than
    /// nuance. Prices per MTok in/out at the time of writing: Sonnet 5
    /// $2/$10 (introductory, $3/$15 from 1 Sep 2026), Opus 5 $5/$25,
    /// Fable 5 $10/$50, Haiku 4.5 $1/$5.
    ///
    /// From the 4.6 generation on, a DATELESS Anthropic id is a pinned
    /// snapshot rather than a moving pointer, so `claude-sonnet-5` is
    /// safe to ship — it won't silently become a different model.
    /// Haiku keeps its dated id because that generation predates the
    /// change.
    static let availableModels: [(id: String, label: String)] = [
        ("claude-sonnet-5", "Claude Sonnet 5 (recommended)"),
        ("claude-opus-5",   "Claude Opus 5 (highest quality, slower)"),
        ("claude-fable-5",  "Claude Fable 5 (most capable, priciest)"),
        ("claude-haiku-4-5-20251001", "Claude Haiku 4.5 (fastest, cheapest)"),
    ]

    static let defaultModelID = "claude-sonnet-5"
    // 2026-05-27 — retry/backoff helpers lifted out into
    // `CloudHTTPRetry.fetch(request:session:log:)`. Shared between
    // Anthropic + OpenAI providers and any future cloud-LLM path.
}
