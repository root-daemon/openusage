import Foundation

/// Per-million-token USD rates for one model, plus optional long-context tiers and a fast-variant
/// multiplier. All spend imputation (Claude, Codex, Cursor, Grok) prices through these.
struct ModelRates: Sendable, Equatable {
    var inputPerMillion: Double
    var outputPerMillion: Double
    /// 5-minute ephemeral cache writes (Anthropic-style). For providers without a separate
    /// cache-write price this equals the input rate.
    var cacheWritePerMillion: Double
    var cacheReadPerMillion: Double

    /// Rates for the token share above 200k tokens, where the provider prices long context higher.
    var inputAbove200kPerMillion: Double?
    var outputAbove200kPerMillion: Double?
    var cacheWriteAbove200kPerMillion: Double?
    var cacheReadAbove200kPerMillion: Double?

    /// Rate multiplier for the model's "fast" variant (1 when the model has none).
    var fastMultiplier: Double = 1

    /// The same rates with every dollar figure scaled — used to price `-fast` model slugs off their
    /// base entry.
    func scaled(by factor: Double) -> ModelRates {
        ModelRates(
            inputPerMillion: inputPerMillion * factor,
            outputPerMillion: outputPerMillion * factor,
            cacheWritePerMillion: cacheWritePerMillion * factor,
            cacheReadPerMillion: cacheReadPerMillion * factor,
            inputAbove200kPerMillion: inputAbove200kPerMillion.map { $0 * factor },
            outputAbove200kPerMillion: outputAbove200kPerMillion.map { $0 * factor },
            cacheWriteAbove200kPerMillion: cacheWriteAbove200kPerMillion.map { $0 * factor },
            cacheReadAbove200kPerMillion: cacheReadAbove200kPerMillion.map { $0 * factor },
            fastMultiplier: 1
        )
    }
}

/// Token counts split into the buckets that price differently. Every scanner normalizes into this.
struct TokenBreakdown: Sendable, Equatable {
    /// Input tokens billed at the plain input rate (not written to or read from cache).
    var input: Int = 0
    /// Input tokens written to the 5-minute ephemeral cache.
    var cacheWrite5m: Int = 0
    /// Input tokens written to the 1-hour ephemeral cache (billed at 2x input).
    var cacheWrite1h: Int = 0
    var cacheRead: Int = 0
    var output: Int = 0
    /// The request ran the model's "fast" variant (Claude logs carry a `speed` field).
    var isFast: Bool = false

    var totalTokens: Int { input + cacheWrite5m + cacheWrite1h + cacheRead + output }
}

extension ModelRates {
    /// 1-hour cache writes are billed at twice the input rate (ccusage's rule; matches LiteLLM's
    /// explicit `above_1hr` fields where present).
    private static let cacheWrite1hInputMultiplier = 2.0

    /// Dollar cost of `tokens` at these rates, applying >200k tiers and the fast multiplier.
    func costDollars(for tokens: TokenBreakdown) -> Double {
        let multiplier = tokens.isFast ? fastMultiplier : 1
        let cost = tieredCost(tokens.input, inputPerMillion, inputAbove200kPerMillion)
            + tieredCost(tokens.output, outputPerMillion, outputAbove200kPerMillion)
            + tieredCost(tokens.cacheWrite5m, cacheWritePerMillion, cacheWriteAbove200kPerMillion)
            + tieredCost(
                tokens.cacheWrite1h,
                inputPerMillion * Self.cacheWrite1hInputMultiplier,
                inputAbove200kPerMillion.map { $0 * Self.cacheWrite1hInputMultiplier }
            )
            + tieredCost(tokens.cacheRead, cacheReadPerMillion, cacheReadAbove200kPerMillion)
        return cost * multiplier
    }

    private func tieredCost(_ tokens: Int, _ basePerMillion: Double, _ abovePerMillion: Double?) -> Double {
        let threshold = 200_000
        guard tokens > 0 else { return 0 }
        if let abovePerMillion, tokens > threshold {
            return (Double(threshold) * basePerMillion + Double(tokens - threshold) * abovePerMillion) / 1_000_000
        }
        return Double(tokens) * basePerMillion / 1_000_000
    }
}
