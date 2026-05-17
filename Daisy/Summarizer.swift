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

@Generable
nonisolated struct MeetingSummary: Codable, Sendable, Equatable {
    @Guide(description: "Concise 2-4 sentence overview of what the meeting was about and what was discussed. Do not invent details not present in the transcript.")
    let summary: String

    @Guide(description: "Action items extracted from the conversation. Each item must be in imperative form, e.g. 'Send invoice to client' or 'Review the proposal'. Include the responsible person if explicitly mentioned. Return an empty array if no clear actions were discussed.")
    let actionItems: [String]

    @Guide(description: "Open questions or topics that were left unresolved and need follow-up. Empty array if none.")
    let followUps: [String]

    @Guide(description: "Key decisions made during the meeting. Empty array if no concrete decisions were reached.")
    let decisions: [String]
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

    // MARK: - Factory

    /// Build a provider instance for the currently selected kind.
    /// Cheap to make — providers are structs/lightweight classes that
    /// hold no expensive state beyond URLSession references.
    private func makeProvider() -> SummaryProvider {
        switch providerKind {
        case .appleIntelligence:
            return AppleIntelligenceSummarizer()
        case .anthropic:
            return AnthropicAPISummarizer(model: anthropicModel)
        case .openai:
            return OpenAIAPISummarizer(model: openaiModel)
        }
    }
}
