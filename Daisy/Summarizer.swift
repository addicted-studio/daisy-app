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
///
/// Plain Codable struct on purpose — the FoundationModels-backed
/// AppleIntelligenceSummarizer wraps its OWN `@Generable` mirror
/// of these fields (which only compiles on macOS 26+) and converts
/// into this canonical type. Keeps the shared model
/// macOS-14-compatible.
nonisolated struct MeetingSummary: Codable, Sendable, Equatable {
    /// One-sentence elevator pitch — "what was this meeting about?".
    /// Rendered above the topical sections as the lede. For legacy
    /// summaries (written before sections shipped) this carries the
    /// full 2-4 sentence overview and `sections` is empty; UI falls
    /// back to rendering this as a plain paragraph.
    let summary: String

    /// Granola-style topical outline — 3-5 sections, each with a
    /// title and bulleted content (with optional sub-bullets, up to
    /// ~3 levels deep). Empty `[]` for legacy summaries written
    /// before this feature shipped; UI then falls back to rendering
    /// `summary` as a paragraph.
    let sections: [SummarySection]

    /// Imperative next steps with optional owner prefix
    /// (e.g. "Maria: send the contract by Thursday"). Kept as a
    /// flat array even after sections shipped — owners + dates are
    /// the actionable scan-target, sub-grouping under a section
    /// hides them.
    let actionItems: [String]

    /// Ready-to-send follow-up message a client / vendor / partner
    /// could receive. Empty string for purely internal team syncs.
    /// Kept as a Daisy-specific field on top of the Granola-style
    /// outline; useful for SMB workflows where the host hands the
    /// summary to a counterpart right after the call.
    let clientFollowUp: String

    // MARK: - Init

    init(
        summary: String,
        sections: [SummarySection] = [],
        actionItems: [String],
        clientFollowUp: String
    ) {
        self.summary = summary
        self.sections = sections
        self.actionItems = actionItems
        self.clientFollowUp = clientFollowUp
    }

    /// Sentinel for a recording that captured no intelligible speech.
    /// Built WITHOUT calling the LLM (see `Summarizer.summarize`): empty
    /// outline / actions / follow-up, so the card shows one clean line and
    /// the follow-up plaque is suppressed — instead of the model
    /// fabricating an apologetic "the recording failed" summary plus a
    /// matching client follow-up (Egor, 2026-06-13).
    static let noSpeechCaptured = MeetingSummary(
        summary: "No speech was captured in this recording — there's nothing to summarize.",
        sections: [],
        actionItems: [],
        clientFollowUp: ""
    )

    // MARK: - Codable

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.summary = try c.decode(String.self, forKey: .summary)
        // `sections` is new in 1.0.2 — older summary.json files on
        // disk don't carry it. Decode as optional, default to empty
        // array. UI's fallback path renders such legacy summaries as
        // a paragraph (the old behaviour) so users never see "no
        // content" on previously-saved sessions.
        self.sections = try c.decodeIfPresent([SummarySection].self, forKey: .sections) ?? []
        self.actionItems = try c.decodeIfPresent([String].self, forKey: .actionItems) ?? []
        self.clientFollowUp = try c.decodeIfPresent(String.self, forKey: .clientFollowUp) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(summary, forKey: .summary)
        try c.encode(sections, forKey: .sections)
        try c.encode(actionItems, forKey: .actionItems)
        try c.encode(clientFollowUp, forKey: .clientFollowUp)
    }

    private enum CodingKeys: String, CodingKey {
        case summary, sections, actionItems, clientFollowUp
    }
}

/// One topical chunk of the Granola-style outline — a header plus a
/// list of bullets. Bullets can themselves carry sub-bullets, so the
/// section renders as an indented tree like the user's xAID.ai
/// reference. Section count + bullet count per section are not
/// enforced in the type — the prompt tells the model "3-5 sections,
/// 2-6 bullets each" and that's where the constraint lives.
nonisolated struct SummarySection: Codable, Sendable, Equatable {
    let title: String
    let bullets: [SummaryBullet]
}

/// Localised header strings for the summary UI (the Settings →
/// Test summary preview and the SessionDetailView outline). The
/// section CONTENT is localised by the LLM via the language
/// directive in the system prompt; the UI's own structural
/// headers ("Meeting" / "Next actions" / "Follow-up for client /
/// partner") need to match — otherwise a Russian summary lands
/// inside English structural labels, which reads inconsistently.
///
/// `for(language:)` accepts an ISO 639-1 two-letter code OR the
/// "auto" sentinel; unknown codes fall through to English (same
/// default that drives the prompt fallback). Add a case here
/// when adding a new `SummaryLanguage` enum case.
nonisolated struct SummaryLabels: Sendable {
    let meeting: String
    let nextActions: String
    let followUp: String

    static func `for`(language: String?) -> SummaryLabels {
        switch (language ?? "").lowercased() {
        case "ru":
            return SummaryLabels(
                meeting: "Встреча",
                nextActions: "Следующие шаги",
                followUp: "Ответ клиенту / партнёру"
            )
        case "uk":
            return SummaryLabels(
                meeting: "Зустріч",
                nextActions: "Наступні кроки",
                followUp: "Відповідь клієнту / партнеру"
            )
        case "pl":
            return SummaryLabels(
                meeting: "Spotkanie",
                nextActions: "Następne kroki",
                followUp: "Wiadomość do klienta / partnera"
            )
        case "es":
            return SummaryLabels(
                meeting: "Reunión",
                nextActions: "Próximas acciones",
                followUp: "Mensaje al cliente / socio"
            )
        case "fr":
            return SummaryLabels(
                meeting: "Réunion",
                nextActions: "Prochaines actions",
                followUp: "Message au client / partenaire"
            )
        case "de":
            return SummaryLabels(
                meeting: "Meeting",
                nextActions: "Nächste Schritte",
                followUp: "Nachricht an Kunden / Partner"
            )
        case "it":
            return SummaryLabels(
                meeting: "Riunione",
                nextActions: "Prossimi passi",
                followUp: "Messaggio al cliente / partner"
            )
        case "pt":
            return SummaryLabels(
                meeting: "Reunião",
                nextActions: "Próximas ações",
                followUp: "Mensagem para o cliente / parceiro"
            )
        case "ja":
            return SummaryLabels(
                meeting: "ミーティング",
                nextActions: "次のアクション",
                followUp: "クライアント／パートナー向けフォローアップ"
            )
        case "ko":
            return SummaryLabels(
                meeting: "회의",
                nextActions: "다음 단계",
                followUp: "클라이언트 / 파트너 후속 메시지"
            )
        case "zh":
            return SummaryLabels(
                meeting: "会议",
                nextActions: "后续行动",
                followUp: "给客户／合作伙伴的跟进"
            )
        default:
            return SummaryLabels(
                meeting: "Meeting",
                nextActions: "Next actions",
                followUp: "Follow-up for client / partner"
            )
        }
    }
}

/// Single bullet in the outline. Recursive: `children` are deeper
/// sub-bullets. Empty `[]` is the leaf case. Codable is automatic
/// via the synthesised init/encode; recursion works because Swift
/// supports indirect Codable for value types.
nonisolated struct SummaryBullet: Codable, Sendable, Equatable {
    let text: String
    let children: [SummaryBullet]

    init(text: String, children: [SummaryBullet] = []) {
        self.text = text
        self.children = children
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.text = try c.decode(String.self, forKey: .text)
        self.children = try c.decodeIfPresent([SummaryBullet].self, forKey: .children) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
        try c.encode(children, forKey: .children)
    }

    private enum CodingKeys: String, CodingKey {
        case text, children
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
    /// Ollama model + base URL (build 40). Model is the tag the user
    /// has actually pulled (`ollama pull <name>`); base URL is the
    /// Ollama daemon endpoint (default 127.0.0.1:11434, overridable
    /// for users running Ollama on a non-default port).
    var ollamaModel: String {
        didSet { UserDefaults.standard.set(ollamaModel, forKey: Self.kOllamaModel) }
    }
    var ollamaBaseURL: String {
        didSet { UserDefaults.standard.set(ollamaBaseURL, forKey: Self.kOllamaBaseURL) }
    }
    /// LM Studio model + base URL (build 40). Model id must match
    /// what's loaded in the LM Studio UI; base URL is the local-server
    /// endpoint (default 127.0.0.1:1234).
    var lmStudioModel: String {
        didSet { UserDefaults.standard.set(lmStudioModel, forKey: Self.kLMStudioModel) }
    }
    var lmStudioBaseURL: String {
        didSet { UserDefaults.standard.set(lmStudioBaseURL, forKey: Self.kLMStudioBaseURL) }
    }

    // MARK: - Private

    @ObservationIgnored
    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "Summarizer")

    private static let kProvider = "daisy.summaryProvider"
    private static let kAnthropicModel = "daisy.anthropicModel"
    private static let kOpenAIModel = "daisy.openaiModel"
    private static let kOllamaModel = "daisy.ollamaModel"
    private static let kOllamaBaseURL = "daisy.ollamaBaseURL"
    private static let kLMStudioModel = "daisy.lmStudioModel"
    private static let kLMStudioBaseURL = "daisy.lmStudioBaseURL"

    private init() {
        // Default to Apple Intelligence on macOS 26+ (where
        // FoundationModels is available). On macOS 14/15 fall back
        // to Anthropic as the default — it's the lowest-friction
        // path that doesn't require the user to discover the
        // unavailable Apple Intelligence option first.
        let defaultKind: SummaryProviderKind = {
            if #available(macOS 26.0, *) { return .appleIntelligence }
            return .anthropic
        }()
        let storedProvider = UserDefaults.standard.string(forKey: Self.kProvider)
            ?? defaultKind.rawValue
        self.providerKind = SummaryProviderKind(rawValue: storedProvider) ?? defaultKind

        self.anthropicModel = UserDefaults.standard.string(forKey: Self.kAnthropicModel)
            ?? AnthropicAPISummarizer.defaultModelID
        self.openaiModel = UserDefaults.standard.string(forKey: Self.kOpenAIModel)
            ?? OpenAIAPISummarizer.defaultModelID
        self.ollamaModel = UserDefaults.standard.string(forKey: Self.kOllamaModel)
            ?? OllamaAPISummarizer.defaultModelID
        self.ollamaBaseURL = UserDefaults.standard.string(forKey: Self.kOllamaBaseURL)
            ?? OllamaAPISummarizer.defaultBaseURLString
        self.lmStudioModel = UserDefaults.standard.string(forKey: Self.kLMStudioModel)
            ?? LMStudioAPISummarizer.defaultModelID
        self.lmStudioBaseURL = UserDefaults.standard.string(forKey: Self.kLMStudioBaseURL)
            ?? LMStudioAPISummarizer.defaultBaseURLString

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
            // Prefer the SPECIFIC FoundationModels reason (not eligible /
            // not enabled / still downloading / same-language mismatch) so
            // the user sees exactly what to fix, not a generic catch-all.
            if #available(macOS 26.0, *),
               let reason = AppleIntelligenceSummarizer.currentUnavailabilityReason() {
                return reason
            }
            return "Apple Intelligence needs macOS 26 or later. Pick a cloud provider (Anthropic / OpenAI) in Settings → Summary instead."
        case .anthropic:
            return "Anthropic API key is missing. Add it in Settings → Summary Provider."
        case .openai:
            return "OpenAI API key is missing. Add it in Settings → Summary Provider."
        case .ollama:
            return "Couldn't reach Ollama at \(ollamaBaseURL). Open Terminal and run `ollama serve`, then pull a model with `ollama pull \(OllamaAPISummarizer.defaultModelID)`."
        case .lmStudio:
            return "Couldn't reach LM Studio at \(lmStudioBaseURL). Open the LM Studio app, load a model, then start the local server (Developer tab → Start)."
        case .mcp:
            return "MCP summarizer isn't configured. Open Settings → Summary → MCP and set the server URL, tool name, and arguments template."
        }
    }

    // MARK: - Summarize

    /// Returns the produced summary on success, `nil` on failure.
    /// Side-effects (writing `lastSummary` / flipping `isSummarizing`) are
    /// preserved for legacy callers that observe the shared singleton —
    /// new code paths (e.g. RecordingSession's detached post-Stop task)
    /// prefer the return value to avoid a race when a second recording
    /// starts before the first summary lands.
    @discardableResult
    func summarize(transcript: String, title: String, localeHint: String?) async -> MeetingSummary? {
        guard !transcript.isEmpty else { return nil }
        // No intelligible speech → don't hand a near-empty transcript to
        // the LLM (it fabricates an apologetic "recording failed" summary
        // and a client follow-up to match). Short-circuit to a clean
        // empty-state instead (Egor, 2026-06-13).
        if Self.isEffectivelySilent(transcript) {
            lastSummary = .noSpeechCaptured
            lastError = nil
            isSummarizing = false
            log.info("Skipped summary — transcript carried essentially no speech")
            return .noSpeechCaptured
        }
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
            isSummarizing = false
            return summary
        } catch {
            log.error("Summarize failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
            isSummarizing = false
            return nil
        }
    }

    /// True when a transcript carries essentially no speech — a failed or
    /// silent capture. Counts word-like tokens (runs of 2+ letters); a
    /// real meeting, even ~20 seconds, has dozens, so the low threshold
    /// won't swallow short-but-real sessions. Bump it if silent captures
    /// still slip through with more garbled tokens.
    static func isEffectivelySilent(_ transcript: String) -> Bool {
        let words = transcript.split { !$0.isLetter }.filter { $0.count >= 2 }
        return words.count < 8
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
            // FoundationModels (Apple Intelligence's local LLM) is
            // macOS 26+ only. On Sonoma / Sequoia we surface a stub
            // that always reports unready, with a friendly error
            // message — same surface contract as the other
            // unavailable-config providers, so the UI doesn't need
            // version-conditional rendering paths.
            if #available(macOS 26.0, *) {
                return AppleIntelligenceSummarizer()
            }
            return UnavailableAppleIntelligenceProvider()
        case .anthropic:
            return AnthropicAPISummarizer(model: anthropicModel)
        case .openai:
            return OpenAIAPISummarizer(model: openaiModel)
        case .ollama:
            // Parse base URL with fallback to default if user typed
            // something malformed. Both adapters tolerate a missing
            // trailing slash — they `appendingPathComponent` rather
            // than string-concat.
            let url = URL(string: ollamaBaseURL)
                ?? URL(string: OllamaAPISummarizer.defaultBaseURLString)!
            return OllamaAPISummarizer(baseURL: url, model: ollamaModel)
        case .lmStudio:
            let url = URL(string: lmStudioBaseURL)
                ?? URL(string: LMStudioAPISummarizer.defaultBaseURLString)!
            return LMStudioAPISummarizer(baseURL: url, model: lmStudioModel)
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

/// Stub provider used when the user has Apple Intelligence selected
/// but they're running macOS 14/15 (FoundationModels framework
/// doesn't exist). Tells them what to do next — pick another
/// provider — without crashing or pretending it works.
private nonisolated struct UnavailableAppleIntelligenceProvider: SummaryProvider {
    let kind: SummaryProviderKind = .appleIntelligence

    func isReady() async -> Bool { false }

    func summarize(transcript: String, title: String, localeHint: String?) async throws -> MeetingSummary {
        throw SummaryProviderError.modelUnavailable(
            provider: "Apple Intelligence",
            reason: "Apple Intelligence summaries require macOS 26 (Tahoe) or newer. Open Settings → Summary and pick Anthropic, OpenAI, or your local MCP server instead."
        )
    }
}
