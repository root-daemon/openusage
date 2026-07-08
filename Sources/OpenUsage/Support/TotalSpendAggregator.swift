import Foundation

/// The spend period the Total Spend card can show — matching the three per-provider spend tiles
/// `SpendTileMapper` emits, whose line labels double as the lookup keys here.
enum TotalSpendPeriod: String, CaseIterable, Identifiable, Sendable {
    case today = "Today"
    case yesterday = "Yesterday"
    case last30 = "Last 30 Days"

    var id: String { rawValue }

    /// The metric-line label this period sums across providers (identical to the raw value today,
    /// but kept as its own accessor so the two meanings can diverge without a hunt).
    var lineLabel: String { rawValue }

    /// Compact segment title for the period switcher — "Last 30 Days" doesn't fit three-across
    /// in the 320pt popover without shrinking every segment.
    var shortLabel: String {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .last30: "30 Days"
        }
    }
}

/// One provider's contribution to a period's total: the dollars it spent plus whether that number is
/// a local estimate (log-scanned providers) or a measured/billed value (Cursor's CSV).
struct TotalSpendSlice: Identifiable, Equatable {
    let provider: Provider
    let amountUSD: Double
    let estimated: Bool

    var id: String { provider.id }
}

/// A period's cross-provider total: the ranked slices (largest spender first) plus the sum.
struct TotalSpend: Equatable {
    let period: TotalSpendPeriod
    let slices: [TotalSpendSlice]

    var totalUSD: Double { slices.reduce(0) { $0 + $1.amountUSD } }
    /// The combined number is an estimate as soon as any contributor's dollars are imputed locally.
    var isEstimated: Bool { slices.contains(where: \.estimated) }
    var isEmpty: Bool { slices.isEmpty }
}

/// Sums per-provider daily spend into one cross-provider total — the data source for the dashboard's
/// Total Spend ring card. Pure and synchronous: it reads already-refreshed `ProviderSnapshot`s and
/// never fetches. A provider contributes only when its snapshot carries a `.values` line with the
/// period's label *and* that line has a dollar value — a provider with no usage for the period (no
/// line, per `SpendTileMapper`'s no-fabricated-zero rule) is excluded, never counted as $0.
enum TotalSpendAggregator {
    /// The total for one period across `providers` (pass them in display order; ties keep it).
    /// Slices are sorted largest-first so the ring and legend read like a ranking.
    static func total(
        for period: TotalSpendPeriod,
        providers: [Provider],
        snapshots: [String: ProviderSnapshot]
    ) -> TotalSpend {
        let slices = providers.compactMap { provider -> TotalSpendSlice? in
            guard let snapshot = snapshots[provider.id],
                  let line = snapshot.line(label: period.lineLabel),
                  case .values(_, let values, _, _, _, _) = line else { return nil }
            let dollars = values.filter { $0.kind == .dollars }
            guard !dollars.isEmpty else { return nil }
            let amount = dollars.reduce(0) { $0 + $1.number }
            guard amount > 0 else { return nil }
            return TotalSpendSlice(
                provider: provider,
                amountUSD: amount,
                estimated: dollars.contains(where: \.estimated)
            )
        }
        let ranked = slices.sorted { lhs, rhs in
            if lhs.amountUSD != rhs.amountUSD { return lhs.amountUSD > rhs.amountUSD }
            return lhs.provider.displayName.localizedStandardCompare(rhs.provider.displayName) == .orderedAscending
        }
        return TotalSpend(period: period, slices: ranked)
    }
}
