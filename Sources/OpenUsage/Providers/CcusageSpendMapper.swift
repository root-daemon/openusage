import Foundation

/// Turns ccusage's local daily token/cost data into Today / Yesterday / Last 30 Days `MetricLine`s.
/// Shared by the Claude and Codex providers (both read the same `ccusage` CLI), so this lives outside
/// any one provider's mapper rather than being borrowed across provider folders.
enum CcusageSpendMapper {
    static func appendTokenUsage(_ usage: CcusageDailyUsage, to lines: inout [MetricLine], now: Date = Date()) {
        let today = dayKey(from: now)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now).map(dayKey(from:))

        let todayEntry = usage.daily.first { dayKey(fromUsageDate: $0.date) == today }
        let yesterdayEntry = usage.daily.first { dayKey(fromUsageDate: $0.date) == yesterday }

        lines.append(dayUsageLine(label: "Today", entry: todayEntry))
        lines.append(dayUsageLine(label: "Yesterday", entry: yesterdayEntry))

        let totalTokens = usage.daily.reduce(0) { $0 + $1.totalTokens }
        let costSamples = usage.daily.compactMap(\.costUSD)
        let totalCost = costSamples.isEmpty ? nil : costSamples.reduce(0, +)
        if totalTokens > 0 {
            lines.append(.values(label: "Last 30 Days", values: spendValues(tokens: totalTokens, costUSD: totalCost)))
        }
    }

    private static func dayKey(from date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private static func dayKey(fromUsageDate rawDate: String) -> String? {
        let value = rawDate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if let match = value.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) {
            return String(value[match])
        }
        if value.range(of: #"^\d{8}$"#, options: .regularExpression) != nil {
            let year = value.prefix(4)
            let month = value.dropFirst(4).prefix(2)
            let day = value.suffix(2)
            return "\(year)-\(month)-\(day)"
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM dd, yyyy"
        if let date = formatter.date(from: value) {
            return dayKey(from: date)
        }

        if let date = OpenUsageISO8601.date(from: value) {
            return dayKey(from: date)
        }
        return nil
    }

    private static func dayUsageLine(label: String, entry: CcusageDay?) -> MetricLine {
        .values(label: label, values: spendValues(tokens: entry?.totalTokens ?? 0, costUSD: entry?.costUSD))
    }

    /// One period's spend as raw values: the estimated dollars (only when ccusage priced the period)
    /// followed by the measured token count. The token value carries no unit label — the row reads
    /// "$4.08 · 41.3M", with the count understood as tokens from context. A cost-only tile renders the
    /// dollars (with the ⓘ), a tokens-only tile the count (no ⓘ), and a combined tile both — all from
    /// this one row, no fused string and nothing for the menu bar to re-parse.
    private static func spendValues(tokens: Int, costUSD: Double?) -> [MetricValue] {
        var values: [MetricValue] = []
        if let costUSD {
            values.append(MetricValue(number: costUSD, kind: .dollars, estimated: true))
        }
        values.append(MetricValue(number: Double(tokens), kind: .count))
        return values
    }
}
