import XCTest
@testable import OpenUsage

/// Covers the Total Spend card's aggregation rules: which providers contribute to a period's total,
/// how slices rank, and when the combined number counts as estimated.
final class TotalSpendAggregatorTests: XCTestCase {
    private let claude = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
    private let codex = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
    private let cursor = Provider(id: "cursor", displayName: "Cursor", icon: .providerMark("cursor"))

    private func snapshot(_ provider: Provider, lines: [MetricLine]) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: lines,
            refreshedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    private func spendLine(_ label: String, dollars: Double, estimated: Bool = false) -> MetricLine {
        .values(label: label, values: [
            MetricValue(number: dollars, kind: .dollars, estimated: estimated),
            MetricValue(number: 1_000_000, kind: .count, label: "tokens")
        ])
    }

    func testSumsDollarsAcrossProvidersAndRanksLargestFirst() {
        let snapshots = [
            "claude": snapshot(claude, lines: [spendLine("Today", dollars: 2.50, estimated: true)]),
            "cursor": snapshot(cursor, lines: [spendLine("Today", dollars: 7.25)])
        ]

        let total = TotalSpendAggregator.total(for: .today, providers: [claude, codex, cursor], snapshots: snapshots)

        XCTAssertEqual(total.slices.map(\.provider.id), ["cursor", "claude"])
        XCTAssertEqual(total.totalUSD, 9.75, accuracy: 0.0001)
    }

    func testProviderWithoutPeriodLineIsExcludedNotZero() {
        let snapshots = [
            "claude": snapshot(claude, lines: [spendLine("Today", dollars: 1.00)]),
            // Codex has spend for yesterday only — it must not appear in today's slices.
            "codex": snapshot(codex, lines: [spendLine("Yesterday", dollars: 3.00)])
        ]

        let total = TotalSpendAggregator.total(for: .today, providers: [claude, codex], snapshots: snapshots)

        XCTAssertEqual(total.slices.map(\.provider.id), ["claude"])
    }

    func testLineWithoutDollarValueDoesNotContribute() {
        let tokensOnly = MetricLine.values(label: "Today", values: [
            MetricValue(number: 500_000, kind: .count, label: "tokens")
        ])
        let snapshots = ["claude": snapshot(claude, lines: [tokensOnly])]

        let total = TotalSpendAggregator.total(for: .today, providers: [claude], snapshots: snapshots)

        XCTAssertTrue(total.isEmpty)
    }

    func testTotalIsEstimatedWhenAnySliceIsEstimated() {
        let snapshots = [
            "claude": snapshot(claude, lines: [spendLine("Today", dollars: 2.00, estimated: true)]),
            "cursor": snapshot(cursor, lines: [spendLine("Today", dollars: 4.00)])
        ]

        let total = TotalSpendAggregator.total(for: .today, providers: [claude, cursor], snapshots: snapshots)

        XCTAssertTrue(total.isEstimated)
    }

}
