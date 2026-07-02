import Foundation

/// A provider-neutral per-day token/cost series — the shared carrier every spend-tracking provider
/// funnels through `SpendTileMapper` (the Today / Yesterday / Last 30 Days tiles and the Usage Trend
/// chart).
///
/// Sources build it from very different inputs and hand `SpendTileMapper` the same shape so the tiles
/// render identically regardless of origin: Claude/Codex/Grok from their native log scanners, Cursor
/// from its usage CSV export.
///
/// These are internal types with no serialization impact: the local HTTP API serializes `MetricLine`,
/// not these.
struct DailyUsageEntry: Hashable, Sendable {
    var date: String
    var totalTokens: Int
    var costUSD: Double?
}

struct DailyUsageSeries: Hashable, Sendable {
    var daily: [DailyUsageEntry]
}

/// Daily token/cost series plus the per-day models the pricing sources couldn't price — the inputs
/// `SpendTileMapper.appendTokenUsage` needs to render the spend tiles with unknown-model warnings.
/// Shared result shape of the native log scanners (Claude, Codex).
struct LogUsageScan: Sendable {
    var series: DailyUsageSeries
    /// `yyyy-MM-dd` day key → models used that day with no pricing entry (their cost shows as $0).
    var unknownModelsByDay: [String: Set<String>]
}
