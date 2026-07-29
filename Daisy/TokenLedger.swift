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
//  Costs are estimates, never a provider invoice. Daisy keeps a small
//  list of the models it offers in Settings, checked on 2026-07-27.
//  Unknown cloud models remain explicitly unpriced rather than being
//  silently shown as $0. Prices can change between Daisy releases.
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

    var hasActivity: Bool { !isEmpty }

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

    /// A Claude web search can be billed even though it uses no model
    /// tokens, so token count alone is not enough to decide whether this
    /// provider had activity in the selected period.
    var hasActivity: Bool { totalTokens > 0 || webSearches > 0 }
}

/// One concrete model's roll-up. Home renders the token card from this
/// rather than from a provider total: a person can immediately see which
/// model the count and price belong to.
nonisolated struct ModelSpend: Identifiable, Sendable {
    var provider: SummaryProviderKind
    var model: String
    var inputTokens: Int
    var outputTokens: Int
    var cachedInputTokens: Int
    var cacheWriteTokens: Int
    var webSearches: Int
    var calls: Int

    var id: String { "\(provider.rawValue)|\(model)" }
    var totalTokens: Int {
        inputTokens + outputTokens + cachedInputTokens + cacheWriteTokens
    }
    var hasActivity: Bool { totalTokens > 0 || webSearches > 0 }
    // A model identifier should normally always be present. Keep the
    // provider raw value as a safe fallback for legacy rows that predate
    // model tracking, without depending on actor-isolated UI labels.
    var displayName: String { model.isEmpty ? provider.rawValue : model }
}

/// One model's row in the token card: its daily series for the stacked
/// chart, and the totals for its legend line.
nonisolated struct ModelSeriesRow: Identifiable, Sendable {
    let id: String
    let name: String
    /// Input INCLUDING cache reads and cache writes. Those are input
    /// tokens billed at a different rate, not a separate quantity — and
    /// splitting them out here would leave `input + output` short of the
    /// total printed above the chart, which reads as an arithmetic bug.
    let inputTokens: Int
    let outputTokens: Int
    /// Daily totals, one entry per elapsed day of this month, oldest
    /// first. Same window as the total above the chart.
    let values: [Int]
    /// This model's own share of the month's bill. Three outcomes, and
    /// the UI must tell them apart: priced (show it), billed but
    /// unpriced — a cloud model Daisy has no tariff for — and not billed
    /// at all, which is every local provider. Blank means free; an
    /// unpriced CLOUD model shown as blank would read as free while
    /// quietly costing money.
    let cost: TokenCostEstimate

    var totalTokens: Int { inputTokens + outputTokens }
}

// MARK: - Approximate API cost

/// Price estimate for Daisy's own calls during a period. It deliberately
/// excludes local providers and marks an unknown *cloud* model as unpriced
/// instead of pretending its cost is zero.
nonisolated struct TokenCostEstimate: Sendable, Equatable {
    var usd: Double = 0
    var hasPricedUsage = false
    var hasUnpricedBilledUsage = false

    /// Merge two estimates. Both flags are sticky on purpose: a bucket
    /// with one priced and one unpriced model is BOTH "here is a number"
    /// and "this number is short", and dropping either half would make
    /// the total look complete when it isn't.
    static func + (lhs: Self, rhs: Self) -> Self {
        Self(
            usd: lhs.usd + rhs.usd,
            hasPricedUsage: lhs.hasPricedUsage || rhs.hasPricedUsage,
            hasUnpricedBilledUsage: lhs.hasUnpricedBilledUsage || rhs.hasUnpricedBilledUsage
        )
    }
}

/// Public list prices for the small, curated model lists Daisy exposes in
/// Settings, in USD per million tokens. Kept here (rather than fetched at
/// runtime) so calculating a local estimate never sends usage anywhere.
///
/// Models Daisy no longer OFFERS are still priced here: the ledger keeps
/// ~90 days of per-model buckets, so dropping a price would silently
/// re-label a month of real spend as "cost unknown".
///
/// Checked 2026-07-28:
/// - OpenAI GPT-5.6 Sol / Terra / Luna, plus retired GPT-4o / 4o mini /
///   4 Turbo
/// - Anthropic Claude Sonnet 5 / Opus 5 / Fable 5 / Haiku 4.5, plus the
///   4.6 generation
nonisolated enum TokenCostEstimator {
    private struct Price: Sendable {
        var input: Double
        var output: Double
        var cachedInput: Double
        var cacheWrite: Double
        var webSearch: Double
    }

    static func estimate(
        provider: SummaryProviderKind,
        model: String,
        spend: TokenSpend
    ) -> TokenCostEstimate {
        guard spend.hasActivity else { return TokenCostEstimate() }
        guard TokenLedger.isBilled(provider) else { return TokenCostEstimate() }
        guard let price = price(for: provider, model: model) else {
            return TokenCostEstimate(hasUnpricedBilledUsage: true)
        }

        let million = 1_000_000.0
        let usd = Double(spend.inputTokens) / million * price.input
            + Double(spend.outputTokens) / million * price.output
            + Double(spend.cachedInputTokens) / million * price.cachedInput
            + Double(spend.cacheWriteTokens) / million * price.cacheWrite
            + Double(spend.webSearches) * price.webSearch
        return TokenCostEstimate(usd: usd, hasPricedUsage: true)
    }

    /// 2026-09-01 00:00 UTC — when Claude Sonnet 5 leaves introductory
    /// pricing. UTC rather than local: billing boundaries are the
    /// provider's, and a day either way on one model's rate is noise
    /// next to picking the wrong rate for a whole month.
    private static let sonnet5StandardPricingStart: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 1
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar.date(from: components) ?? .distantFuture
    }()

    private static func price(for provider: SummaryProviderKind, model: String) -> Price? {
        let id = model.lowercased()
        switch provider {
        case .anthropic:
            if id.hasPrefix("claude-sonnet-5") {
                // Introductory $2/$10 through 2026-08-31, $3/$15 after.
                // Date-aware rather than pinned because the card's
                // window is the CURRENT calendar month — so a given
                // month is billed entirely at one rate or the other,
                // and "today's rate" is the right rate for it.
                let standard = Date() >= Self.sonnet5StandardPricingStart
                return standard
                    ? Price(input: 3, output: 15, cachedInput: 0.30, cacheWrite: 3.75, webSearch: 0.01)
                    : Price(input: 2, output: 10, cachedInput: 0.20, cacheWrite: 2.50, webSearch: 0.01)
            }
            if id.hasPrefix("claude-opus-5") {
                return Price(input: 5, output: 25, cachedInput: 0.50, cacheWrite: 6.25, webSearch: 0.01)
            }
            if id.hasPrefix("claude-fable-5") {
                return Price(input: 10, output: 50, cachedInput: 1.00, cacheWrite: 12.50, webSearch: 0.01)
            }
            if id.hasPrefix("claude-sonnet-4-6") {
                // $3 / $15, cache write $3.75, cache read $0.30, web $10 / 1K.
                return Price(input: 3, output: 15, cachedInput: 0.30, cacheWrite: 3.75, webSearch: 0.01)
            }
            if id.hasPrefix("claude-opus-4-6") {
                return Price(input: 5, output: 25, cachedInput: 0.50, cacheWrite: 6.25, webSearch: 0.01)
            }
            if id.hasPrefix("claude-haiku-4-5") {
                return Price(input: 1, output: 5, cachedInput: 0.10, cacheWrite: 1.25, webSearch: 0.01)
            }
        case .openai:
            // Cached input is 10% of input across the 5.6 family, and
            // Chat Completions caching is automatic — there is no
            // separate cache-WRITE charge to model.
            if id.hasPrefix("gpt-5.6-sol") {
                return Price(input: 5, output: 30, cachedInput: 0.50, cacheWrite: 0, webSearch: 0)
            }
            if id.hasPrefix("gpt-5.6-terra") {
                return Price(input: 2.50, output: 15, cachedInput: 0.25, cacheWrite: 0, webSearch: 0)
            }
            if id.hasPrefix("gpt-5.6-luna") {
                return Price(input: 1, output: 6, cachedInput: 0.10, cacheWrite: 0, webSearch: 0)
            }
            if id.hasPrefix("gpt-4o-mini") {
                return Price(input: 0.15, output: 0.60, cachedInput: 0.075, cacheWrite: 0, webSearch: 0)
            }
            if id.hasPrefix("gpt-4o") {
                return Price(input: 2.50, output: 10, cachedInput: 1.25, cacheWrite: 0, webSearch: 0)
            }
            if id.hasPrefix("gpt-4-turbo") {
                // Chat Completions does not report cached tokens for this
                // legacy model in Daisy today; count any future value at
                // the normal input rate rather than inventing a discount.
                return Price(input: 10, output: 30, cachedInput: 10, cacheWrite: 0, webSearch: 0)
            }
        case .appleIntelligence, .ollama, .lmStudio, .mcp:
            return nil
        }
        return nil
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
        currentMonthSpend().contains(where: \.hasActivity)
    }

    /// The provider whose number the card leads with: the one currently
    /// selected if it spent anything this month, otherwise the biggest
    /// spender. Never a cross-provider sum.
    func heroSpend(active: SummaryProviderKind) -> ProviderSpend? {
        let all = currentMonthSpend().filter(\.hasActivity)
        return all.first { $0.provider == active } ?? all.first
    }

    /// Everything except the hero, biggest first — the small rows under
    /// the divider. Non-empty exactly when more than one provider was
    /// used this month (switched provider mid-month, or a cloud
    /// pre-meeting brief alongside a local summarizer).
    func secondarySpend(active: SummaryProviderKind) -> [ProviderSpend] {
        guard let hero = heroSpend(active: active) else { return [] }
        return currentMonthSpend().filter { $0.hasActivity && $0.id != hero.id }
    }

    /// Model-level roll-up for the Home card. A model is never mixed with
    /// another model just because both happen to use the same provider.
    func currentMonthModelSpend() -> [ModelSpend] {
        modelSpend(matchingDayPrefix: Self.monthKey(for: Date()))
    }

    /// Every token Daisy spent this month, across every model.
    ///
    /// Summing tokens across models is fine as a VOLUME measure and
    /// wrong as a cost proxy — a Haiku token and an Opus token are the
    /// same unit of work and five times apart in price. That's why the
    /// money next to it comes from `currentMonthCostEstimate()`, which
    /// prices each model separately, rather than from this number.
    func currentMonthTotalTokens() -> Int {
        currentMonthModelSpend().reduce(0) { $0 + $1.totalTokens }
    }

    /// The price estimate for one model's own tokens. Keeping the scope
    /// this narrow is what stops a Claude row from displaying OpenAI
    /// spend.
    func currentMonthCostEstimate(for modelSpend: ModelSpend) -> TokenCostEstimate {
        costEstimate(
            matchingDayPrefix: Self.monthKey(for: Date()),
            provider: modelSpend.provider,
            model: modelSpend.model
        )
    }

    /// Rows for the stacked chart + legend, biggest spender first.
    ///
    /// Capped at `limit` distinct models: a stack of eight is mush, and
    /// the categorical palette only has four slots that survive a
    /// colour-blindness check. Anything past the cap is merged into one
    /// trailing "Other" row rather than dropped — a silently truncated
    /// stack reads as "this is everything".
    func currentMonthModelSeries(limit: Int = 4) -> [ModelSeriesRow] {
        // `hasActivity`, so the rows' costs add up to the headline: a
        // model with web searches and no tokens still costs real money
        // ($0.01 a search), and the headline counts every bucket. Filter
        // it out of the table and the column silently stops summing to
        // the number above it. The row reads "0 in, 0 out" with a price
        // beside it, which is exactly what happened.
        let all = currentMonthModelSpend().filter(\.hasActivity)
        guard !all.isEmpty else { return [] }
        let leading = all.prefix(limit)
        let merged = all.dropFirst(limit)

        var rows = leading.map { spend in
            ModelSeriesRow(
                id: spend.id,
                name: Self.friendlyModelName(spend.model, provider: spend.provider),
                inputTokens: spend.inputTokens + spend.cachedInputTokens + spend.cacheWriteTokens,
                outputTokens: spend.outputTokens,
                values: currentMonthTokenSeries(for: spend),
                cost: currentMonthCostEstimate(for: spend)
            )
        }
        if !merged.isEmpty {
            let series = merged.map { currentMonthTokenSeries(for: $0) }
            let length = series.map(\.count).max() ?? 0
            let summed = (0..<length).map { day in
                series.reduce(0) { $0 + ($1.indices.contains(day) ? $1[day] : 0) }
            }
            rows.append(ModelSeriesRow(
                id: "other",
                name: String(localized: "\(merged.count) other models"),
                inputTokens: merged.reduce(0) { $0 + $1.inputTokens + $1.cachedInputTokens + $1.cacheWriteTokens },
                outputTokens: merged.reduce(0) { $0 + $1.outputTokens },
                values: summed,
                cost: merged.reduce(TokenCostEstimate()) { $0 + currentMonthCostEstimate(for: $1) }
            ))
        }
        return rows
    }

    /// Web searches this month across every model — billed per search
    /// rather than per token, so they are invisible in any token figure
    /// and have to be named separately.
    func currentMonthWebSearches() -> Int {
        currentMonthModelSpend().reduce(0) { $0 + $1.webSearches }
    }

    /// Input tokens served from a provider's prompt cache this month.
    /// Counted inside the input figures, but billed at roughly a tenth —
    /// so it's the line that explains a small bill next to a large token
    /// count, and it is invisible in every other number on the card.
    func currentMonthCachedInputTokens() -> Int {
        currentMonthModelSpend().reduce(0) { $0 + $1.cachedInputTokens }
    }

    /// Readable model name. Conservative on purpose: it strips the two
    /// things that make an id ugly — Anthropic's `claude-` prefix and a
    /// trailing `-YYYYMMDD` snapshot stamp — and rewrites the Claude
    /// family's dashed version into a dotted one. Everything else is
    /// passed through untouched, because a guessed prettier name that
    /// doesn't match what the user picked in Settings is worse than a
    /// plain identifier.
    nonisolated static func friendlyModelName(_ model: String, provider: SummaryProviderKind) -> String {
        guard !model.isEmpty else { return provider.rawValue }
        guard provider == .anthropic, model.hasPrefix("claude-") else { return model }
        var parts = model.dropFirst("claude-".count).split(separator: "-").map(String.init)
        // Trailing snapshot stamp: 8 digits, e.g. 20251001.
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) {
            parts.removeLast()
        }
        guard let family = parts.first else { return model }
        // Every component after the family must be a number, or this
        // isn't the `family-major-minor` shape and we'd be inventing a
        // name. `claude-3-5-sonnet-20241022` would otherwise come out as
        // "3 5.sonnet" — worse than the id the user actually chose.
        let versionParts = parts.dropFirst()
        guard versionParts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
            return model
        }
        let version = versionParts.joined(separator: ".")
        let name = family.prefix(1).uppercased() + family.dropFirst()
        return version.isEmpty ? name : "\(name) \(version)"
    }

    /// Daily values for the small chart in the model card, oldest first.
    /// Empty days intentionally stay as zero-height bars: the quiet gaps
    /// are useful context, not missing data.
    func currentMonthTokenSeries(for modelSpend: ModelSpend) -> [Int] {
        // Gregorian explicitly, matching `UsageStats.dayKey` and
        // `monthKey`. `Calendar.current` follows the user's locale
        // calendar, so on a Hebrew or Islamic calendar the day-of-month
        // it reports belongs to a different month than the total and the
        // cost printed above the chart — the series would silently cover
        // the wrong window.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let today = Date()
        let day = calendar.component(.day, from: today)
        // One bar per elapsed day of THIS month — the same window the
        // numbers above the chart use. A rolling 14-day series (what this
        // was) quietly described a different period than the total right
        // next to it, so labelling the card would have made the card lie.
        return (0..<day).map { offset in
            guard let date = calendar.date(byAdding: .day, value: offset - day + 1, to: today) else {
                return 0
            }
            let key = UsageStats.dayKey(for: date)
            return (days[key] ?? [])
                .filter { $0.provider == modelSpend.provider.rawValue && $0.model == modelSpend.model }
                .reduce(0) { $0 + $1.totalTokens }
        }
    }

    /// Approximate USD cost of all paid Daisy calls in the current month.
    /// Local providers are excluded. If the user entered a custom cloud
    /// model whose tariff Daisy does not know, `hasUnpricedBilledUsage` is
    /// set so the UI can avoid presenting a misleading total.
    func currentMonthCostEstimate() -> TokenCostEstimate {
        costEstimate(matchingDayPrefix: Self.monthKey(for: Date()))
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

    private func modelSpend(matchingDayPrefix prefix: String) -> [ModelSpend] {
        var totals: [String: ModelSpend] = [:]

        for (dayKey, buckets) in days where dayKey.hasPrefix(prefix) {
            for bucket in buckets {
                guard let provider = SummaryProviderKind(rawValue: bucket.provider) else { continue }
                let key = "\(bucket.provider)|\(bucket.model)"
                var running = totals[key] ?? ModelSpend(
                    provider: provider, model: bucket.model,
                    inputTokens: 0, outputTokens: 0, cachedInputTokens: 0,
                    cacheWriteTokens: 0, webSearches: 0, calls: 0
                )
                running.inputTokens += bucket.inputTokens
                running.outputTokens += bucket.outputTokens
                running.cachedInputTokens += bucket.cachedInputTokens
                running.cacheWriteTokens += bucket.cacheWriteTokens
                running.webSearches += bucket.webSearches
                running.calls += bucket.calls
                totals[key] = running
            }
        }

        return totals.values.sorted {
            if $0.totalTokens != $1.totalTokens { return $0.totalTokens > $1.totalTokens }
            return $0.calls > $1.calls
        }
    }

    private func costEstimate(
        matchingDayPrefix prefix: String,
        provider targetProvider: SummaryProviderKind? = nil,
        model targetModel: String? = nil
    ) -> TokenCostEstimate {
        var total = TokenCostEstimate()
        for (dayKey, buckets) in days where dayKey.hasPrefix(prefix) {
            for bucket in buckets {
                guard let provider = SummaryProviderKind(rawValue: bucket.provider) else { continue }
                guard targetProvider == nil || provider == targetProvider,
                      targetModel == nil || bucket.model == targetModel else { continue }
                let one = TokenCostEstimator.estimate(
                    provider: provider,
                    model: bucket.model,
                    spend: TokenSpend(
                        inputTokens: bucket.inputTokens,
                        outputTokens: bucket.outputTokens,
                        cachedInputTokens: bucket.cachedInputTokens,
                        cacheWriteTokens: bucket.cacheWriteTokens,
                        webSearches: bucket.webSearches
                    )
                )
                total.usd += one.usd
                total.hasPricedUsage = total.hasPricedUsage || one.hasPricedUsage
                total.hasUnpricedBilledUsage = total.hasUnpricedBilledUsage || one.hasUnpricedBilledUsage
            }
        }
        return total
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
