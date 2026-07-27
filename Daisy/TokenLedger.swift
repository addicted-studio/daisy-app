//
//  TokenLedger.swift
//  Daisy
//
//  Local ledger of the tokens Daisy itself spent on cloud LLM calls.
//  Every provider already reports its own token counts in the response
//  body (Anthropic `usage`, OpenAI/LM Studio `usage`, Ollama
//  `prompt_eval_count`/`eval_count`) — before this file those numbers
//  were parsed past and thrown away. Now they land here.
//
//  What this is NOT: the provider's bill. Daisy only sees ITS OWN calls,
//  so the number here is always ≤ what the provider's console shows
//  (other apps, the Workbench, and retried-then-charged attempts are all
//  invisible to us). The UI says "spent by Daisy" for exactly that
//  reason. Account-wide spend would need the Usage/Cost Admin APIs, and
//  those want an org-level admin key that individual accounts don't have
//  — see Projects/Daisy/2026-07-27-token-spend-widget-research.md.
//
//  Deliberately token-only: no prices, no dollars. A hardcoded price
//  table goes stale between releases and then Daisy confidently lies
//  about money. Cost is a separate decision (same research note).
//
//  100% local (UserDefaults JSON). Never leaves the Mac. Bucketed per
//  local day × provider × model, pruned to `retentionDays`.
//

import Foundation
import Observation

// MARK: - One call's reported cost

/// Token cost of a single provider call, exactly as the provider
/// reported it. `nonisolated` so the provider structs can build one off
/// the main actor.
nonisolated struct TokenSpend: Sendable {
    /// Fresh (uncached) input tokens.
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    /// Input served from the provider's prompt cache — billed at a
    /// discount, so it's tracked apart from `inputTokens` rather than
    /// folded in. Daisy doesn't use prompt caching today; the field is
    /// here so the numbers stay honest if it starts.
    var cachedInputTokens: Int = 0
    /// Cache-write tokens — billed at a premium.
    var cacheWriteTokens: Int = 0
    /// Anthropic server-tool web searches (pre-meeting brief research).
    /// Billed PER SEARCH, not per token — the most expensive thing Daisy
    /// can trigger per unit, and invisible if you only count tokens.
    var webSearches: Int = 0

    var isEmpty: Bool {
        inputTokens == 0 && outputTokens == 0 && cachedInputTokens == 0
            && cacheWriteTokens == 0 && webSearches == 0
    }

    // MARK: Response parsers
    //
    // All three are defensive: a missing or reshaped `usage` block
    // yields an empty spend, which `TokenLedgerSink.record` drops. A
    // provider changing its response shape must never break a summary.

    /// Anthropic Messages API: `usage: { input_tokens, output_tokens,
    /// cache_creation_input_tokens, cache_read_input_tokens,
    /// server_tool_use: { web_search_requests } }`.
    static func anthropic(from json: [String: Any]) -> TokenSpend {
        guard let usage = json["usage"] as? [String: Any] else { return TokenSpend() }
        var spend = TokenSpend()
        spend.inputTokens = intValue(usage["input_tokens"])
        spend.outputTokens = intValue(usage["output_tokens"])
        spend.cacheWriteTokens = intValue(usage["cache_creation_input_tokens"])
        spend.cachedInputTokens = intValue(usage["cache_read_input_tokens"])
        if let tools = usage["server_tool_use"] as? [String: Any] {
            spend.webSearches = intValue(tools["web_search_requests"])
        }
        return spend
    }

    /// OpenAI chat completions and everything that mimics it (LM Studio):
    /// `usage: { prompt_tokens, completion_tokens,
    /// prompt_tokens_details: { cached_tokens } }`. `prompt_tokens`
    /// INCLUDES cached tokens upstream, so the cached slice is
    /// subtracted out to keep `inputTokens` meaning "fresh input" the
    /// same way it does for Anthropic.
    static func openAICompatible(from json: [String: Any]) -> TokenSpend {
        guard let usage = json["usage"] as? [String: Any] else { return TokenSpend() }
        var spend = TokenSpend()
        let prompt = intValue(usage["prompt_tokens"])
        if let details = usage["prompt_tokens_details"] as? [String: Any] {
            spend.cachedInputTokens = intValue(details["cached_tokens"])
        }
        spend.inputTokens = max(0, prompt - spend.cachedInputTokens)
        spend.outputTokens = intValue(usage["completion_tokens"])
        return spend
    }

    /// Ollama `/api/chat`: `prompt_eval_count` + `eval_count` at the top
    /// level. Known upstream quirk — `prompt_eval_count` can be absent
    /// or reset when the prompt is served from Ollama's own cache
    /// (ollama#2068, ollama#3427), so the input half undercounts on
    /// repeat prompts. Harmless here: Ollama is local and free, the
    /// number is informational only.
    static func ollama(from json: [String: Any]) -> TokenSpend {
        var spend = TokenSpend()
        spend.inputTokens = intValue(json["prompt_eval_count"])
        spend.outputTokens = intValue(json["eval_count"])
        return spend
    }

    /// JSON numbers arrive as NSNumber, Int, or Double depending on the
    /// serializer's mood. Anything else counts as zero.
    private static func intValue(_ any: Any?) -> Int {
        switch any {
        case let n as Int: return max(0, n)
        case let n as NSNumber: return max(0, n.intValue)
        case let d as Double: return max(0, Int(d))
        default: return 0
        }
    }
}

// MARK: - Persisted bucket

/// Per-day, per-provider, per-model aggregate. Stored as an ARRAY per
/// day rather than a nested dictionary — a Codable dictionary key would
/// have to be a composite string like `"anthropic|claude-sonnet-4-6"`,
/// and parsing that back apart is exactly the kind of thing that rots.
/// A day holds a handful of buckets at most.
nonisolated struct TokenBucket: Codable, Sendable, Equatable {
    /// `SummaryProviderKind.rawValue`. Kept as a String so an unknown
    /// value from a future build decodes instead of throwing.
    var provider: String
    /// Model identifier as configured when the call was made.
    var model: String
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cachedInputTokens: Int = 0
    var cacheWriteTokens: Int = 0
    var webSearches: Int = 0
    /// Successful calls that reported usage.
    var calls: Int = 0

    var totalTokens: Int {
        inputTokens + outputTokens + cachedInputTokens + cacheWriteTokens
    }

    init(provider: String, model: String) {
        self.provider = provider
        self.model = model
    }

    // Tolerant decode — older persisted rows may lack newer fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = (try? c.decode(String.self, forKey: .provider)) ?? ""
        model = (try? c.decode(String.self, forKey: .model)) ?? ""
        inputTokens = (try? c.decode(Int.self, forKey: .inputTokens)) ?? 0
        outputTokens = (try? c.decode(Int.self, forKey: .outputTokens)) ?? 0
        cachedInputTokens = (try? c.decode(Int.self, forKey: .cachedInputTokens)) ?? 0
        cacheWriteTokens = (try? c.decode(Int.self, forKey: .cacheWriteTokens)) ?? 0
        webSearches = (try? c.decode(Int.self, forKey: .webSearches)) ?? 0
        calls = (try? c.decode(Int.self, forKey: .calls)) ?? 0
    }

    mutating func add(_ spend: TokenSpend) {
        inputTokens += spend.inputTokens
        outputTokens += spend.outputTokens
        cachedInputTokens += spend.cachedInputTokens
        cacheWriteTokens += spend.cacheWriteTokens
        webSearches += spend.webSearches
        calls += 1
    }
}

/// One provider's roll-up over a period, ready to render. Tokens are
/// NEVER summed across providers: a Claude token and a GPT token cost
/// different money and mean different things, so one combined number
/// would be adding rubles to dollars.
nonisolated struct ProviderSpend: Identifiable, Sendable {
    var provider: SummaryProviderKind
    /// Models used in the period, most-used first.
    var models: [String]
    var inputTokens: Int
    var outputTokens: Int
    var cachedInputTokens: Int
    var cacheWriteTokens: Int
    var webSearches: Int
    var calls: Int

    var id: String { provider.rawValue }
    var totalTokens: Int {
        inputTokens + outputTokens + cachedInputTokens + cacheWriteTokens
    }
}

// MARK: - Ledger

@MainActor
@Observable
final class TokenLedger {
    static let shared = TokenLedger()

    /// How much per-day history is kept. The display window is the
    /// current calendar MONTH (that's what providers bill on, so it's
    /// the only number comparable to their console) — retention runs
    /// wider so a "last month" comparison or a sparkline can be added
    /// later without having thrown the data away. Pruning is silent by
    /// design but bounded and documented here; at ~a handful of buckets
    /// per active day the whole store is tens of KB.
    static let retentionDays = 90

    private static let defaultsKey = "daisy.tokenLedger"

    /// Keyed by `yyyy-MM-dd` (local day), same key format as
    /// `UsageStats` so the two can be joined later.
    private(set) var days: [String: [TokenBucket]]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: [TokenBucket]].self, from: data) {
            days = decoded
        } else {
            days = [:]
        }
        pruneOldDays()
    }

    // MARK: Record

    /// Fold one call's reported usage into today's bucket for
    /// (provider, model). No-op for an empty spend so a provider that
    /// omits `usage` doesn't inflate the call count.
    func record(provider: SummaryProviderKind, model: String, spend: TokenSpend) {
        guard !spend.isEmpty else { return }
        let key = UsageStats.dayKey(for: Date())
        var buckets = days[key] ?? []
        if let idx = buckets.firstIndex(where: { $0.provider == provider.rawValue && $0.model == model }) {
            buckets[idx].add(spend)
        } else {
            var bucket = TokenBucket(provider: provider.rawValue, model: model)
            bucket.add(spend)
            buckets.append(bucket)
        }
        days[key] = buckets
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(days) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    /// Drop day rows older than `retentionDays`. `yyyy-MM-dd` sorts
    /// lexicographically in chronological order, so a string compare is
    /// enough — no date parsing per key.
    private func pruneOldDays() {
        guard let cutoffDate = Calendar.current.date(
            byAdding: .day, value: -Self.retentionDays, to: Date()
        ) else { return }
        let cutoff = UsageStats.dayKey(for: cutoffDate)
        let stale = days.keys.filter { $0 < cutoff }
        guard !stale.isEmpty else { return }
        for key in stale { days.removeValue(forKey: key) }
        persist()
    }

    // MARK: Queries

    /// Roll-up per provider for the current calendar month, biggest
    /// spender first. Buckets whose provider no longer maps to a known
    /// kind are skipped rather than guessed at.
    func currentMonthSpend() -> [ProviderSpend] {
        spend(matchingDayPrefix: Self.monthKey(for: Date()))
    }

    /// Gate for showing the Home card: at least one provider produced
    /// tokens this month. Local providers count — for them the card
    /// reports volume and says "free" instead of implying a bill, which
    /// is more useful than hiding the card from the majority of users
    /// who never point Daisy at a paid API.
    var hasSpendThisMonth: Bool {
        currentMonthSpend().contains { $0.totalTokens > 0 }
    }

    /// The provider whose number the card leads with: the one currently
    /// selected if it spent anything this month, otherwise the biggest
    /// spender. Never a cross-provider sum.
    func heroSpend(active: SummaryProviderKind) -> ProviderSpend? {
        let all = currentMonthSpend().filter { $0.totalTokens > 0 }
        return all.first { $0.provider == active } ?? all.first
    }

    /// Everything except the hero, biggest first — the small rows under
    /// the divider. Non-empty exactly when more than one provider was
    /// used this month (switched provider mid-month, or a cloud
    /// pre-meeting brief alongside a local summarizer).
    func secondarySpend(active: SummaryProviderKind) -> [ProviderSpend] {
        guard let hero = heroSpend(active: active) else { return [] }
        return currentMonthSpend().filter { $0.totalTokens > 0 && $0.id != hero.id }
    }

    private func spend(matchingDayPrefix prefix: String) -> [ProviderSpend] {
        // provider → (totals, model → calls) so models can be ordered
        // by how much they were actually used.
        var totals: [String: ProviderSpend] = [:]
        var modelCalls: [String: [String: Int]] = [:]

        for (dayKey, buckets) in days where dayKey.hasPrefix(prefix) {
            for bucket in buckets {
                guard let kind = SummaryProviderKind(rawValue: bucket.provider) else { continue }
                var running = totals[bucket.provider] ?? ProviderSpend(
                    provider: kind, models: [], inputTokens: 0, outputTokens: 0,
                    cachedInputTokens: 0, cacheWriteTokens: 0, webSearches: 0, calls: 0
                )
                running.inputTokens += bucket.inputTokens
                running.outputTokens += bucket.outputTokens
                running.cachedInputTokens += bucket.cachedInputTokens
                running.cacheWriteTokens += bucket.cacheWriteTokens
                running.webSearches += bucket.webSearches
                running.calls += bucket.calls
                totals[bucket.provider] = running

                if !bucket.model.isEmpty {
                    modelCalls[bucket.provider, default: [:]][bucket.model, default: 0] += max(1, bucket.calls)
                }
            }
        }

        return totals.values
            .map { entry in
                var out = entry
                out.models = (modelCalls[entry.provider.rawValue] ?? [:])
                    .sorted { lhs, rhs in
                        if lhs.value != rhs.value { return lhs.value > rhs.value }
                        return lhs.key < rhs.key
                    }
                    .map(\.key)
                return out
            }
            .sorted { $0.totalTokens > $1.totalTokens }
    }

    // MARK: Helpers

    /// Providers that actually cost money. Ollama and LM Studio run on
    /// the user's own machine; Apple Intelligence is on-device. MCP is
    /// whatever the user pointed it at, so we don't claim to know.
    ///
    /// Caveat worth remembering: an Ollama model tagged `:cloud` proxies
    /// to ollama.com and IS billed there — Daisy relabels those in the
    /// picker but can't see their price, so they stay "not billed" here
    /// rather than showing a number we'd be inventing.
    nonisolated static func isBilled(_ kind: SummaryProviderKind) -> Bool {
        switch kind {
        case .anthropic, .openai: return true
        case .appleIntelligence, .ollama, .lmStudio, .mcp: return false
        }
    }

    /// `yyyy-MM` for the local month containing `date` — a prefix of the
    /// day keys, so filtering is a `hasPrefix`.
    nonisolated static func monthKey(for date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let c = cal.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }
}

// MARK: - Recording from nonisolated provider code

/// Fire-and-forget entry point for the provider structs, which are
/// `nonisolated` and parse responses off the main actor while
/// `TokenLedger` is `@MainActor`. Never throws, never blocks the call it
/// is measuring, and drops empty spends.
nonisolated enum TokenLedgerSink {
    static func record(provider: SummaryProviderKind, model: String, spend: TokenSpend) {
        guard !spend.isEmpty else { return }
        Task { @MainActor in
            TokenLedger.shared.record(provider: provider, model: model, spend: spend)
        }
    }

    /// Convenience for the Anthropic response shape.
    static func recordAnthropic(model: String, json: [String: Any]) {
        record(provider: .anthropic, model: model, spend: .anthropic(from: json))
    }
}
