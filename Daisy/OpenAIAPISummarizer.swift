//
//  OpenAIAPISummarizer.swift
//  Daisy
//
//  SummaryProvider that calls OpenAI's Chat Completions API in JSON
//  mode. User supplies their own API key (stored in Keychain).
//

import Foundation
import os

nonisolated struct OpenAIAPISummarizer: SummaryProvider {
    let kind: SummaryProviderKind = .openai

    /// Model identifier. See `availableModels` for the shipped list.
    let model: String
    let urlSession: URLSession

    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "OpenAISummarizer")

    init(model: String = defaultModelID, urlSession: URLSession = .shared) {
        self.model = model
        self.urlSession = urlSession
    }

    func isReady() async -> Bool {
        if let key = KeychainStore.get(account: SecretKey.openaiAPIKey), !key.isEmpty {
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
        guard let apiKey = KeychainStore.get(account: SecretKey.openaiAPIKey),
              !apiKey.isEmpty else {
            throw SummaryProviderError.missingAPIKey(provider: "OpenAI")
        }

        let systemPrompt = SummaryPrompt.systemInstructions(localeHint: localeHint, task: task)
        let userPrompt = SummaryPrompt.userPrompt(title: title, transcript: trimmed, task: task)

        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user",   "content": userPrompt]
            ],
            // JSON mode — model is guaranteed to return parseable JSON.
            "response_format": ["type": "json_object"]
        ]
        // The GPT-5 generation speaks a different dialect of the same
        // endpoint: `max_tokens` is rejected in favour of
        // `max_completion_tokens`, and `temperature` only accepts its
        // default. Sending the old shape returns HTTP 400 "Unsupported
        // parameter", so branch instead of assuming.
        if Self.usesGPT5ParameterSet(model) {
            // Higher than the 4096 below on purpose: this budget covers
            // REASONING tokens as well as the visible answer, and a
            // summary that spends its whole allowance thinking comes
            // back with empty content.
            body["max_completion_tokens"] = 16_384
        } else {
            // 4096 (was 2048 pre-1.0.3) — see AnthropicAPISummarizer
            // for the long-meeting truncation rationale.
            body["max_tokens"] = 4096
            body["temperature"] = 0.4
        }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        // Retry on transient 429 / 5xx / network errors — shared
        // helper in CloudHTTPRetry (pre-1.0.7.3 this lived on
        // AnthropicAPISummarizer, cross-provider naming was awkward).
        let (data, response) = try await CloudHTTPRetry.fetch(
            request: request,
            session: urlSession,
            log: log
        )
        guard let http = response as? HTTPURLResponse else {
            throw SummaryProviderError.invalidResponse(provider: "OpenAI")
        }
        if !(200..<300).contains(http.statusCode) {
            let bodyString = String(data: data, encoding: .utf8) ?? "<empty>"
            // bodyString stays .private — same reasoning as in
            // AnthropicAPISummarizer: 4xx bodies can quote the prompt
            // back, which would put transcript fragments in the
            // unified log.
            log.error("OpenAI HTTP \(http.statusCode): \(bodyString, privacy: .private)")
            throw SummaryProviderError.httpError(
                provider: "OpenAI",
                status: http.statusCode,
                body: bodyString
            )
        }

        // Response shape (chat completions):
        // { "choices": [{ "message": { "content": "<JSON>" }, ... }], ... }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SummaryProviderError.invalidResponse(provider: "OpenAI")
        }

        // Usage is billable even if a successful response later proves
        // unusable as a Daisy summary, so record it before shape checks.
        TokenLedgerSink.record(
            provider: .openai,
            model: model,
            spend: .openAICompatible(from: json)
        )

        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw SummaryProviderError.invalidResponse(provider: "OpenAI")
        }

        do {
            let dto = try CloudSummaryDTO.decode(from: content)
            return dto.toMeetingSummary()
        } catch {
            throw SummaryProviderError.parseFailed(
                provider: "OpenAI",
                message: error.localizedDescription
            )
        }
    }

    // MARK: - Catalog of model IDs offered in Settings

    /// Refreshed 2026-07-28. `gpt-4-turbo` is gone from the list because
    /// it is deprecated with a 2026-10-23 shutdown (`gpt-5` /
    /// `gpt-5-mini` follow on 2026-12-11).
    /// Prices per MTok in/out: Sol $5/$30, Terra $2.50/$15, Luna $1/$6.
    /// Terra leads because a meeting summary is a mid-difficulty job on
    /// a lot of tokens — Sol's headroom rarely shows up in the output
    /// and always shows up on the bill.
    ///
    /// GPT-4o and GPT-4o mini stay on the list. They are not being shut
    /// down — they only fell out of the current price sheet — and mini
    /// at $0.15/$0.60 is an order of magnitude cheaper than anything in
    /// the 5.6 generation. Users on them are not migrated, so dropping
    /// them here would make the picker a one-way door: switch away once
    /// and there is no field to type the id back in.
    static let availableModels: [(id: String, label: String)] = [
        ("gpt-5.6-terra", "GPT-5.6 Terra (recommended)"),
        ("gpt-5.6-sol",   "GPT-5.6 Sol (highest quality, slower)"),
        ("gpt-5.6-luna",  "GPT-5.6 Luna (fastest, cheapest)"),
        ("gpt-4o",        "GPT-4o (previous generation)"),
        ("gpt-4o-mini",   "GPT-4o mini (previous generation, cheapest)"),
    ]

    static let defaultModelID = "gpt-5.6-terra"

    /// True for the GPT-5 generation and the o-series reasoning models,
    /// which take `max_completion_tokens` and refuse a custom
    /// `temperature`. Prefix-matched rather than an allow-list so a
    /// model released after this build still gets the right dialect —
    /// and so a user who types their own id into Settings isn't handed
    /// a 400 we could have avoided.
    static func usesGPT5ParameterSet(_ model: String) -> Bool {
        let id = model.lowercased()
        return id.hasPrefix("gpt-5")
            || id.hasPrefix("o1")
            || id.hasPrefix("o3")
            || id.hasPrefix("o4")
    }
}
