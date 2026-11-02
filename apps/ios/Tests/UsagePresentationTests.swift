import Foundation

@main struct UsagePresentationTests {
    static func main() {
        let values = [
            UsageDayValue(day: "2026-01-01", seconds: 3600),
            UsageDayValue(day: "2026-01-03", seconds: 10800),
            UsageDayValue(day: "2026-02-01", seconds: 0),
            UsageDayValue(day: "2026-02-03", seconds: 7200),
            UsageDayValue(day: "2025-01-01", seconds: 360000)
        ]
        let total = UsageStatistics.months(values, year: 2026, metric: .total)
        precondition(total.count == 12 && total[0].hours == 4 && total[1].hours == 2)
        precondition(total[2...].allSatisfy { $0.hours == 0 })
        let average = UsageStatistics.months(values, year: 2026, metric: .average)
        precondition(average[0].hours == 2 && average[1].hours == 1)
        precondition(average[2].hours == 0) // Missing dates aren't treated as zero-use days.
        let cumulative = UsageStatistics.months(values, year: 2026, metric: .cumulative)
        precondition(cumulative[0].hours == 4 && cumulative[1...].allSatisfy { $0.hours == 6 })
        precondition(UsageStatistics.months([], year: 2026, metric: .average).allSatisfy { $0.hours == 0 })

        let available: Set<String> = ["2026-01-01", "2026-01-03", "2024-02-29"]
        precondition(UsageDates.canSelect(DateComponents(year: 2026, month: 1, day: 1), available: available))
        precondition(!UsageDates.canSelect(DateComponents(year: 2026, month: 1, day: 2), available: available))
        precondition(!UsageDates.canSelect(DateComponents(year: 2025, month: 1, day: 1), available: available))
        precondition(UsageDates.canSelect(DateComponents(year: 2024, month: 2, day: 29), available: available))
        precondition(!UsageDates.canSelect(DateComponents(year: 2026, month: 2, day: 29), available: available))
        precondition(!UsageDates.canSelect(DateComponents(year: 2026, month: 1), available: available))
        precondition(UsageDates.key(DateComponents(year: 2026, month: 2, day: 31)) == nil)
        for day in available {
            let date = UsageDates.date(day)!
            let parts = UsageDates.calendar.dateComponents([.year, .month, .day], from: date)
            precondition(UsageDates.key(parts) == day)
        }
        precondition(UsageDates.title("2026-01-03") == "2026 年 1 月 3 日")
        precondition(UsageDates.duration(3660) == "1小时 1分")
        let base = UsageDates.date("2026-01-01")!
        func value(_ offset: Int, _ hours: Double) -> UsageDayValue {
            let date = UsageDates.calendar.date(byAdding: .day, value: offset, to: base)!
            return UsageDayValue(day: UsageDates.formatter().string(from: date), seconds: hours * 3600)
        }
        let history = [value(1, 1000), value(-180, 99), value(-179, 6), value(-89, 4), value(-29, 2), value(-6, 1), value(0, 3)]
        for (series, expected) in [(UsageDailySeries.week, 2.0), (.month, 2.0), (.quarter, 2.5), (.halfYear, 3.2)] {
            let points = UsageStatistics.days(history, year: 2026, series: series)
            precondition(points.count == 2 && points[0].day == "2026-01-01")
            precondition(abs(points[0].hours - expected) < 0.000001)
        }
        let daily = UsageStatistics.days(history, year: 2026, series: .daily)
        precondition(daily.map(\.hours) == [3, 1000])
        // Natural-day windows, rather than the last N recorded entries.
        let sparse = [value(0, 2), value(20, 8)]
        precondition(UsageStatistics.days(sparse, year: 2026, series: .week).last?.hours == 8)
        precondition(UsageStatistics.days(sparse, year: 2026, series: .month).last?.hours == 5)
        // A recorded zero counts in the denominator; missing dates do not.
        precondition(UsageStatistics.days([value(0, 0), value(2, 4)], year: 2026, series: .week).last?.hours == 2)
        precondition(UsageStatistics.days([], year: 2026, series: .halfYear).isEmpty)
        let leap = [UsageDayValue(day: "2024-02-29", seconds: 3600), UsageDayValue(day: "2024-03-06", seconds: 10800)]
        precondition(UsageStatistics.days(leap, year: 2024, series: .week).last?.hours == 2)
        print("Usage presentation tests passed: monthly and daily totals, 7/30/90/180-day averages, cross-year history, missing and zero days, window boundaries and sparse calendar availability")
    }
}
