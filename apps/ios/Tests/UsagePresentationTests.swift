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
        print("Usage presentation tests passed: annual totals, recorded-day averages, cumulative hours, sparse calendar availability and leap days")
    }
}
