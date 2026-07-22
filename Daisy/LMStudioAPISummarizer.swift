//
//  LMStudioAPISummarizer.swift
//  Daisy
//
//  SummaryProvider that talks to a locally-running LM Studio
//  (https://lmstudio.ai) via its OpenAI-compatible
//  `/v1/chat/completions` REST endpoint. No API key required — LM Studio
//  binds to 127.0.0.1:1234 by default and accepts unauthenticated requests.
//  Data never leaves the Mac.
//
//  Why this exists as a first-class provider (build 40):
//  Pre-build-40 the "LM Studio" option in Settings → Summary Provider
//  routed through `MCPSummarizer` with a preset baseURL and a JSON
//  arguments template that assumed an MCP+SSE shim was running. But
//  LM Studio does NOT speak MCP — it speaks OpenAI-compatible REST.
//  Picking "LM Studio" without first wiring up an MCP shim caused
//  every summary to fail with a cryptic SSE handshake error. The
//  pre-PH audit (2026-05-28) flagged this as a P0 blocker.
//
//  This adapter posts to `/v1/chat/completions` directly — the request
//  shape is identical to OpenAIAPISummarizer except for the base URL
//  and the absence of Authorization header. Probe via `/v1/models`.
//

import Foundation
import os

nonisolated struct LMStudioAPISummarizer: SummaryProvider {
    let kind: SummaryProviderKind = .lmStudio

    /// Base URL of the LM Studio server. Default: `http://127.0.0.1:1234`.
    let baseURL: URL

    /// LM Studio model identifier. Must already be loaded in the
    /// LM Studio UI (the user picks the model from LM Studio's
    /// model picker; this string matches what the server reports
    /// via `/v1/models`).
    let model: String

    let urlSession: URLSession

    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "LMStudioSummarizer")

    init(
        baseURL: URL = URL(string: "http://127.0.0.1:1234")!,
        model: String = "qwen2.5-7b-instruct",
        urlSession: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.model = model
        self.urlSession = urlSession
    }

    /// "Is LM Studio's server actually running with a model loaded?"
    /// probe via `/v1/models`. Returns false on any network error or
    /// non-2xx status. If the LM Studio app is running but no model
    /// is loaded, `/v1/models` returns 200 with an empty list — we
    /// still consider that "reachable", and let the actual summarize
    /// surface the no-model-loaded error if/when the user records.
    func isReady() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/models"))
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        do {
            let (_, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
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

        let systemPrompt = SummaryPrompt.systemInstructions(localeHint: localeHint, task: task)
        let userPrompt = SummaryPrompt.userPrompt(title: title, transcript: trimmed, task: task)

        // Request shape identical to OpenAI's chat.completions —
        // LM Studio's local server is API-compatible.
        // NOTE — deliberately NO `response_format`. LM Studio's newer
        // server builds reject `{"type":"json_object"}` outright with
        // HTTP 400 (`'response_format.type' must be 'json_schema' or
        // 'text'`) — the OpenAI-style json_object mode simply isn't a
        // valid value there (GitHub #5). Rather than pin a brittle,
        // version-specific `json_schema` (unsupported on older builds),
        // we rely entirely on the prompt's JSON instructions plus the
        // tolerant `CloudSummaryDTO.decode` (fence-stripping + balanced-
        // brace extraction + alias retry), which is what actually parses
        // every local provider's output anyway.
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user",   "content": userPrompt]
            ],
            "max_tokens": 4096,
            "temperature": 0.4,
            "stream": false
        ]

        var request = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Same 180s timeout as Ollama — local 7B models on M-series
        // hardware can take 30-60s for long transcripts.
        request.timeoutInterval = 180
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw SummaryProviderError.modelUnavailable(
                provider: "LM Studio",
                reason: "Couldn't reach LM Studio at \(baseURL.absoluteString). Open the LM Studio app, load a model, and start the server (Developer tab → Start). (\(error.localizedDescription))"
            )
        }
        guard let http = response as? HTTPURLResponse else {
            throw SummaryProviderError.invalidResponse(provider: "LM Studio")
        }
        if !(200..<300).contains(http.statusCode) {
            let bodyString = String(data: data, encoding: .utf8) ?? "<empty>"
            log.error("LM Studio HTTP \(http.statusCode): \(bodyString, privacy: .private)")
            throw SummaryProviderError.httpError(
                provider: "LM Studio",
                status: http.statusCode,
                body: bodyString
            )
        }

        // Response shape (OpenAI-compatible):
        // { "choices": [{ "message": { "content": "<JSON>" }, ... }], ... }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw SummaryProviderError.invalidResponse(provider: "LM Studio")
        }

        do {
            let dto = try CloudSummaryDTO.decode(from: content)
            return dto.toMeetingSummary()
        } catch {
            throw SummaryProviderError.parseFailed(
                provider: "LM Studio",
                message: error.localizedDescription
            )
        }
    }

    // MARK: - Catalog

    /// Default model id. LM Studio model IDs depend on what the
    /// user has downloaded — there's no universal name. We default
    /// to the most-likely-pulled multilingual 7B; user MUST edit
    /// this in Settings to match a model they've actually loaded
    /// in LM Studio. If the id mismatches, LM Studio returns 404.
    static let defaultModelID = "qwen2.5-7b-instruct"

    /// Default base URL. Stock LM Studio binds here when its local
    /// server is started.
    static let defaultBaseURLString = "http://127.0.0.1:1234"

    /// Catalog of commonly-loaded LM Studio model IDs. Strictly a
    /// hint — the user's actual loaded model name (visible in
    /// LM Studio's UI under "API Identifier") is the source of truth.
    static let availableModels: [(id: String, label: String)] = [
        ("qwen2.5-7b-instruct",    "Qwen 2.5 7B Instruct — multilingual, recommended"),
        ("qwen2.5-14b-instruct",   "Qwen 2.5 14B Instruct — multilingual, more capable"),
        ("llama-3.2-3b-instruct",  "Llama 3.2 3B Instruct — fast"),
        ("llama-3.1-8b-instruct",  "Llama 3.1 8B Instruct"),
        ("mistral-7b-instruct-v0.3", "Mistral 7B Instruct v0.3"),
        ("gemma-2-9b-it",          "Gemma 2 9B Instruct"),
    ]
}
