//
//  Summarizer.swift
//  Daisy
//
//  Observable façade for the summarization pipeline. The UI talks to
//  exactly one Summarizer; it dispatches to the user-selected
//  SummaryProvider (Apple Intelligence / Anthropic / OpenAI) under the
//  hood. Keeps `lastSummary`, `isSummarizing`, `lastError`, and
//  `availability` reactive so the SwiftUI views update automatically.
//

import Foundation
import FoundationModels
import Observation
import os

/// Three-section meeting summary:
///  1. `summary` — what the meeting was about (the "встреча" section)
///  2. `actionItems` — block of next steps the participants will take
///  3. `clientFollowUp` — ready-to-send draft message a client or
///     partner could receive (separate from internal action items)
///
/// Older builds wrote `decisions` and `followUps` arrays into
/// `summary.json`; those keys are silently ignored by the current
/// decoder. The custom `init(from:)` also defaults `clientFollowUp`
/// to an empty string for legacy files that don't carry it yet —
/// the UI hides that section when empty.
@Generable
nonisolated struct MeetingSummary: Codable, Sendable, Equatable {
    @Guide(description: "Concise 2-4 sentence overview of what the meeting was about and what was discussed. Do not invent details not present in the transcript.")
    let summary: String

    @Guide(description: "Block of next actions agreed on during the meeting — what the participants will do after the call ends. Each item in imperative form, e.g. 'Send invoice to client' or 'Review the proposal'. Include the responsible person if explicitly mentioned. Empty array if no clear actions were discussed.")
    let actionItems: [String]

    @Guide(description: "Ready-to-send follow-up message that a client or partner from this meeting could receive. Write in the second person, polite-professional tone, no greeting boilerplate beyond a single short opener. Cover what was discussed and what the next steps are from their perspective. If the meeting was internal-only with no external counterpart, return an empty string. 80-180 words.")
    let clientFollowUp: String

    // MARK: - Init

    init(summary: String, actionItems: [String], clientFollowUp: String) {
        self.summary = summary
        self.actionItems = actionItems
        self.clientFollowUp = clientFollowUp
    }

    // MARK: - Codable

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.summary = try c.decode(String.self, forKey: .summary)
        self.actionItems = try c.decodeIfPresent([String].self, forKey: .actionItems) ?? []
        self.clientFollowUp = try c.decodeIfPresent(String.self, forKey: .clientFollowUp) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(summary, forKey: .summary)
        try c.encode(actionItems, forKey: .actionItems)
        try c.encode(clientFollowUp, forKey: .clientFollowUp)
    }

    private enum CodingKeys: String, CodingKey {
        case summary, actionItems, clientFollowUp
    }
}

@Observable
@MainActor
final class Summarizer {
    enum AvailabilityState: Equatable {
        case unknown
        case available
        case unavailable(String)
    }

    /// Shared instance — Summarizer holds the user's provider preference,
    /// API model selections, and the most recent result. Both Settings UI
    /// and RecordingSession bind to the same object.
    static let shared = Summarizer()

    // MARK: - Observable

    private(set) var availability: AvailabilityState = .unknown
    private(set) var isSummarizing = false
    private(set) var lastSummary: MeetingSummary?
    private(set) var lastError: String?

    /// Which provider is currently selected. Persisted to UserDefaults.
    /// Changing it triggers an availability re-check.
    var providerKind: SummaryProviderKind {
        didSet {
            guard oldValue != providerKind else { return }
            UserDefaults.standard.set(providerKind.rawValue, forKey: Self.kProvider)
            Task { await refreshAvailability() }
        }
    }

    /// Model ID selected per cloud provider (Anthropic / OpenAI).
    /// Apple Intelligence has no choice. Persisted independently so the
    /// user's pick survives switching providers back and forth.
    var anthropicModel: String {
        didSet { UserDefaults.standard.set(anthropicModel, forKey: Self.kAnthropicModel) }
    }
    var openaiModel: String {
        didSet { UserDefaults.standard.set(openaiModel, forKey: Self.kOpenAIModel) }
    }

    // MARK: - Private

    @ObservationIgnored
    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "Summarizer")

    private static let kProvider = "daisy.summaryProvider"
    private static let kAnthropicModel = "daisy.anthropicModel"
    private static let kOpenAIModel = "daisy.openaiModel"

    private init() {
        let storedProvider = UserDefaults.standard.string(forKey: Self.kProvider)
            ?? SummaryProviderKind.appleIntelligence.rawValue
        self.providerKind = SummaryProviderKind(rawValue: storedProvider) ?? .appleIntelligence

        self.anthropicModel = UserDefaults.standard.string(forKey: Self.kAnthropicModel)
            ?? AnthropicAPISummarizer.defaultModelID
        self.openaiModel = UserDefaults.standard.string(forKey: Self.kOpenAIModel)
            ?? OpenAIAPISummarizer.defaultModelID

        Task { await refreshAvailability() }
    }

    // MARK: - Availability

    func refreshAvailability() async {
        let provider = makeProvider()
        let ready = await provider.isReady()
        if ready {
            availability = .available
        } else {
            availability = .unavailable(reasonForCurrent())
        }
    }

    private func reasonForCurrent() -> String {
        switch providerKind {
        case .appleIntelligence:
            return "Apple Intelligence is not available on this Mac, not enabled, or still downloading. Check System Settings → Apple Intelligence & Siri, or pick a different provider in Settings → Summary Provider."
        case .anthropic:
            return "Anthropic API key is missing. Add it in Settings → Summary Provider."
        case .openai:
            return "OpenAI API key is missing. Add it in Settings → Summary Provider."
        case .mcp:
            return "MCP summarizer isn't configured. Open Settings → Summary → MCP and set the server URL, tool name, and arguments template."
        }
    }

    // MARK: - Summarize

    func summarize(transcript: String, title: String, localeHint: String?) async {
        guard !transcript.isEmpty else { return }
        isSummarizing = true
        lastError = nil

        let provider = makeProvider()
        do {
            let summary = try await provider.summarize(
                transcript: transcript,
                title: title,
                localeHint: localeHint
            )
            lastSummary = summary
            log.info("Summarized via \(self.providerKind.shortName, privacy: .public)")
        } catch {
            log.error("Summarize failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
        isSummarizing = false
    }

    func clear() {
        lastSummary = nil
        lastError = nil
    }

    /// Isolated "dry run" — used by Settings → Test summary so the
    /// probe doesn't bleed into shared state. Does NOT touch
    /// `lastSummary`, `lastError`, or `isSummarizing`, so an
    /// in-flight real summary on the active session keeps its own
    /// state.
    ///
    /// Returns either the produced summary or a thrown error, so the
    /// caller can render its own one-shot preview without polluting
    /// the singleton.
    func runProbe(transcript: String, title: String, localeHint: String?) async throws -> MeetingSummary {
        let provider = makeProvider()
        return try await provider.summarize(
            transcript: transcript,
            title: title,
            localeHint: localeHint
        )
    }

    // MARK: - Factory

    /// Build a provider instance for the currently selected kind.
    /// Cheap to make — providers are structs/lightweight classes that
    /// hold no expensive state beyond URLSession references.
    ///
    /// MCP provider reads its config from UserDefaults directly so
    /// Summarizer stays AppSettings-agnostic. If the URL is missing
    /// or malformed we fall back to an UnavailableProvider that
    /// always fails — surfaces as a friendly error in the UI rather
    /// than a crash.
    private func makeProvider() -> SummaryProvider {
        switch providerKind {
        case .appleIntelligence:
            return AppleIntelligenceSummarizer()
        case .anthropic:
            return AnthropicAPISummarizer(model: anthropicModel)
        case .openai:
            return OpenAIAPISummarizer(model: openaiModel)
        case .mcp:
            let defaults = UserDefaults.standard
            let urlString = defaults.string(forKey: "daisy.mcpSummarizer.url")
                ?? MCPSummarizer.defaultBaseURLString
            let toolName = defaults.string(forKey: "daisy.mcpSummarizer.toolName")
                ?? MCPSummarizer.defaultToolName
            let template = defaults.string(forKey: "daisy.mcpSummarizer.argsTemplate")
                ?? MCPSummarizer.defaultArgumentsTemplate
            guard let url = URL(string: urlString), url.scheme != nil else {
                return UnavailableMCPProvider(reason: "MCP server URL is empty or malformed: \"\(urlString)\"")
            }
            return MCPSummarizer(
                baseURL: url,
                toolName: toolName,
                argumentsTemplate: template
            )
        }
    }
}

// MARK: - Fallback

/// Stub provider used when the .mcp config can't be parsed. Always
/// reports unready and throws a useful error on summarize — keeps
/// the surface area uniform so callers don't need switch coverage
/// for config errors.
private nonisolated struct UnavailableMCPProvider: SummaryProvider {
    let kind: SummaryProviderKind = .mcp
    let reason: String

    func isReady() async -> Bool { false }

    func summarize(transcript: String, title: String, localeHint: String?) async throws -> MeetingSummary {
        throw SummaryProviderError.modelUnavailable(provider: "MCP", reason: reason)
    }
}
