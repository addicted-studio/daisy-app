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

    /// Model identifier. Defaults to Sonnet 4.6 — strong quality/cost.
    let model: String
    /// Override for testing; production passes URLSession.shared.
    let urlSession: URLSession

    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "AnthropicSummarizer")

    init(model: String = "claude-sonnet-4-6", urlSession: URLSession = .shared) {
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
        localeHint: String?
    ) async throws -> MeetingSummary {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 40 else {
            throw SummaryProviderError.transcriptTooShort
        }
        guard let apiKey = KeychainStore.get(account: SecretKey.anthropicAPIKey),
              !apiKey.isEmpty else {
            throw SummaryProviderError.missingAPIKey(provider: "Anthropic")
        }

        let systemPrompt = SummaryPrompt.systemInstructions(localeHint: localeHint)
        let userPrompt = SummaryPrompt.userPrompt(title: title, transcript: trimmed)

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2048,
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

        let (data, response) = try await urlSession.data(for: request)
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
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
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

    static let availableModels: [(id: String, label: String)] = [
        ("claude-sonnet-4-6", "Claude Sonnet 4.6 (recommended)"),
        ("claude-opus-4-6",   "Claude Opus 4.6 (highest quality, slower)"),
        ("claude-haiku-4-5-20251001", "Claude Haiku 4.5 (fastest, cheapest)"),
    ]

    static let defaultModelID = "claude-sonnet-4-6"
}
