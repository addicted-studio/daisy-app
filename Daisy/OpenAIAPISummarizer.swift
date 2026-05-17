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

    /// Model identifier. Default is gpt-4o — well-priced + multilingual.
    let model: String
    let urlSession: URLSession

    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "OpenAISummarizer")

    init(model: String = "gpt-4o", urlSession: URLSession = .shared) {
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
        localeHint: String?
    ) async throws -> MeetingSummary {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 40 else {
            throw SummaryProviderError.transcriptTooShort
        }
        guard let apiKey = KeychainStore.get(account: SecretKey.openaiAPIKey),
              !apiKey.isEmpty else {
            throw SummaryProviderError.missingAPIKey(provider: "OpenAI")
        }

        let systemPrompt = SummaryPrompt.systemInstructions(localeHint: localeHint)
        let userPrompt = SummaryPrompt.userPrompt(title: title, transcript: trimmed)

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user",   "content": userPrompt]
            ],
            // JSON mode — model is guaranteed to return parseable JSON.
            "response_format": ["type": "json_object"],
            "max_tokens": 2048,
            "temperature": 0.4
        ]

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SummaryProviderError.invalidResponse(provider: "OpenAI")
        }
        if !(200..<300).contains(http.statusCode) {
            let bodyString = String(data: data, encoding: .utf8) ?? "<empty>"
            log.error("OpenAI HTTP \(http.statusCode): \(bodyString, privacy: .public)")
            throw SummaryProviderError.httpError(
                provider: "OpenAI",
                status: http.statusCode,
                body: bodyString
            )
        }

        // Response shape (chat completions):
        // { "choices": [{ "message": { "content": "<JSON>" }, ... }], ... }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
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

    static let availableModels: [(id: String, label: String)] = [
        ("gpt-4o",      "GPT-4o (recommended)"),
        ("gpt-4o-mini", "GPT-4o mini (fast, cheap)"),
        ("gpt-4-turbo", "GPT-4 Turbo (legacy)"),
    ]

    static let defaultModelID = "gpt-4o"
}
