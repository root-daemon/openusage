import XCTest
@testable import OpenUsage

/// Covers the relative/absolute reset display: the shared `Formatters.deadlineLabel` (one helper for
/// every "<verb> + when" string), its absolute day buckets (ported from the original
/// `formatResetAbsoluteLabel`), and `WidgetData` honoring the global mode for the trailing label,
/// the opposite-format tooltip, and the "Limit in …" run-out projection.
final class ResetDisplayTests: XCTestCase {
    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func testAbsoluteLabelDayBuckets() {
        let calendar = utcCalendar()
        let now = calendar.date(from: DateComponents(year: 2024, month: 6, day: 1, hour: 12))! // noon, stable

        XCTAssertTrue(Formatters.resetAbsoluteLabel(at: now.addingTimeInterval(2 * 3600),
                                                    now: now, calendar: calendar)!.hasPrefix("Resets today at "))

        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!.addingTimeInterval(3600)
        XCTAssertTrue(Formatters.resetAbsoluteLabel(at: tomorrow,
                                                    now: now, calendar: calendar)!.hasPrefix("Resets tomorrow at "))

        let later = calendar.date(byAdding: .day, value: 5, to: now)!
        let label = Formatters.resetAbsoluteLabel(at: later, now: now, calendar: calendar)!
        XCTAssertTrue(label.hasPrefix("Resets ") && label.contains(" at "))
        XCTAssertFalse(label.hasPrefix("Resets today"))
        XCTAssertFalse(label.hasPrefix("Resets tomorrow"))

        XCTAssertEqual(Formatters.resetAbsoluteLabel(at: now.addingTimeInterval(-1),
                                                     now: now, calendar: calendar), "Resets soon")
    }

    func testWidgetDataTrailingAndTooltipHonorMode() {
        var data = WidgetData(title: "Weekly", icon: .symbol("clock"),
                              kind: .percent, used: 50, limit: 100)
        data.resetsAt = Date().addingTimeInterval(4 * 24 * 3600 + 17 * 3600) // ~4d17h out
        data.periodDurationMs = 7 * 24 * 60 * 60 * 1000
        XCTAssertTrue(data.hasResetLabel)

        data.resetDisplayMode = .relative
        XCTAssertEqual(data.boundedTrailingText?.hasPrefix("Resets in "), true)
        XCTAssertEqual(data.resetTooltip?.hasPrefix("Resets "), true)         // opposite = absolute

        data.resetDisplayMode = .absolute
        XCTAssertEqual(data.boundedTrailingText?.hasPrefix("Resets "), true)
        XCTAssertEqual(data.resetTooltip?.hasPrefix("Resets in "), true)      // opposite = relative
    }

    func testDeadlineLabelSharesFormatAcrossPrefixesAndModes() {
        let calendar = utcCalendar()
        let now = calendar.date(from: DateComponents(year: 2024, month: 6, day: 1, hour: 12))!

        XCTAssertEqual(Formatters.deadlineLabel("Runs out", at: now.addingTimeInterval(2 * 3600 + 360),
                                                mode: .relative, now: now), "Runs out in 2h 6m")
        XCTAssertTrue(Formatters.deadlineLabel("Runs out", at: now.addingTimeInterval(2 * 3600),
                                               mode: .absolute, now: now, calendar: calendar)!
            .hasPrefix("Runs out today at "))
        // Imminent deadlines collapse to "soon" in both modes, same as the reset label.
        XCTAssertEqual(Formatters.deadlineLabel("Runs out", at: now.addingTimeInterval(60),
                                                mode: .relative, now: now), "Runs out soon")
        XCTAssertEqual(Formatters.deadlineLabel("Runs out", at: now.addingTimeInterval(-1),
                                                mode: .absolute, now: now, calendar: calendar), "Runs out soon")
    }

    /// The `runningOut` run-out time, present only when the bar is red and projects to run out
    /// before the reset. Evaluated against the real clock (default `now`) to match the resetsAt set
    /// from `Date()` below.
    private func runningOutEta(_ data: WidgetData) -> String? {
        if case .runningOut(let eta, _) = data.meterState() { return eta }
        return nil
    }

    func testRunningOutEtaHonorsResetDisplayMode() {
        // Halfway through a 10h window with 90/100 used → behind pace, projected run-out ~34m away,
        // safely before the reset 5h out. The label carries its own "Limit" verb (no flame in tests),
        // so the copy reads "Limit in 34m" / "Limit today at …".
        var data = WidgetData(title: "Session", icon: .symbol("clock"),
                              kind: .percent, used: 90, limit: 100)
        data.resetsAt = Date().addingTimeInterval(5 * 3600)
        data.periodDurationMs = 10 * 3600 * 1000

        data.resetDisplayMode = .relative
        XCTAssertEqual(runningOutEta(data)?.hasPrefix("Limit in "), true) // e.g. "Limit in 34m"
        XCTAssertEqual(runningOutEta(data)?.hasSuffix("m"), true)         // compact duration like "34m"

        data.resetDisplayMode = .absolute
        // Wall-clock reading ~34m out: "Limit today at …", or "Limit tomorrow at …" when the test runs
        // near local midnight (`WidgetData` evaluates against the real clock, so the bucket can roll).
        let absolute = runningOutEta(data)
        XCTAssertEqual(absolute?.hasPrefix("Limit today at ") == true
                        || absolute?.hasPrefix("Limit tomorrow at ") == true, true)
    }

    func testNoResetLabelWithoutResetDate() {
        var data = WidgetData(title: "Credits", icon: .symbol("creditcard"),
                              kind: .dollars, used: 12, limit: 20)
        data.resetDisplayMode = .absolute
        XCTAssertFalse(data.hasResetLabel)          // no resetsAt → not a clickable reset
        XCTAssertNil(data.resetTooltip)
        XCTAssertEqual(data.boundedTrailingText, "$20 limit") // falls back to limit context, unflipped
    }
}
