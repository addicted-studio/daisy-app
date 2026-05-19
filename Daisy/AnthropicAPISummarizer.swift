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
            // 4096 (was 2048 pre-1.0.3) — long Russian / German / Polish
            // summaries hit the 2048 ceiling on hour-long meetings,
            // truncating the clientFollowUp draft mid-sentence. 4096
            // covers the worst realistic case at ~1.5 hour meetings;
            // cost delta is ~0.5¢ per call at Sonnet 4.6 list.
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
        let (data, response) = try await Self.fetchWithRetry(
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

    // MARK: - Shared retry helper (used by Anthropic + OpenAI paths)

    /// Run an HTTP request with exponential-backoff retries on
    /// transient failures: 429 (rate limit), 5xx server errors, and
    /// URLSession transient network errors (timeout / connection
    /// dropped / DNS hiccup). Up to 3 attempts total with delays
    /// 1s → 2s → 4s between them.
    ///
    /// Permanent failures (4xx other than 429, malformed responses,
    /// any error that isn't in the transient list) are returned
    /// immediately so the caller sees the actual error.
    ///
    /// `nonisolated` because both cloud providers are nonisolated
    /// structs and call this from their `summarize(...)` async
    /// functions. No shared mutable state — pure retry logic over
    /// the URLSession argument.
    nonisolated static func fetchWithRetry(
        request: URLRequest,
        session: URLSession,
        log: Logger,
        maxAttempts: Int = 3
    ) async throws -> (Data, URLResponse) {
        var lastError: (any Error)?
        for attempt in 1...maxAttempts {
            do {
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse,
                   Self.isTransientStatus(http.statusCode),
                   attempt < maxAttempts {
                    let delay = Self.backoffDelay(forAttempt: attempt)
                    log.warning("HTTP \(http.statusCode, privacy: .public) — retry in \(Int(delay), privacy: .public)s (attempt \(attempt, privacy: .public)/\(maxAttempts, privacy: .public))")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                return (data, response)
            } catch {
                lastError = error
                if Self.isTransientURLError(error), attempt < maxAttempts {
                    let delay = Self.backoffDelay(forAttempt: attempt)
                    log.warning("Network error — retry in \(Int(delay), privacy: .public)s (attempt \(attempt, privacy: .public)/\(maxAttempts, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                throw error
            }
        }
        // We only reach here if the final attempt produced a
        // transient HTTP status — surface it via the caller's
        // normal HTTP-status error path by returning the last
        // response. But the `for` loop always either returns or
        // throws, so this is unreachable; satisfy the compiler.
        throw lastError ?? SummaryProviderError.invalidResponse(provider: "cloud")
    }

    nonisolated private static func isTransientStatus(_ code: Int) -> Bool {
        return code == 429 || (500...599).contains(code)
    }

    nonisolated private static func isTransientURLError(_ error: any Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return false }
        switch ns.code {
        case NSURLErrorTimedOut,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorNotConnectedToInternet,
             NSURLErrorDNSLookupFailed,
             NSURLErrorCannotConnectToHost,
             NSURLErrorCannotFindHost:
            return true
        default:
            return false
        }
    }

    nonisolated private static func backoffDelay(forAttempt attempt: Int) -> TimeInterval {
        // 1s, 2s, 4s — geometric backoff. Plenty for transient
        // gateway hiccups, short enough not to time out the
        // summary task entirely (which has its own timeout
        // ceiling upstream).
        return pow(2.0, Double(attempt - 1))
    }
}
