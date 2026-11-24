import Foundation

struct InvestmentProfitCalendarData: Sendable {
    struct Summary: Sendable {
        let first: Date?
        let last: Date?
        let expectedDays: Int
        let recordedDays: Int
        let knownGain: Decimal?
        var missingDays: Int { expectedDays - recordedDays }
        var gain: Decimal? { expectedDays > 0 && missingDays == 0 ? knownGain : nil }
    }

    struct Month: Identifiable, Sendable {
        let start: Date
        let end: Date
        let number: Int
        let summary: Summary
        var id: Date { start }
    }

    let start: Date
    let dailyGains: [Date: Decimal]
    let months: [Month]
    let summary: Summary

    init(book: InvestmentBook, yearContaining date: Date, today: Date) {
        let calendar = InvestmentBook.calendar
        let today = InvestmentBook.day(today)
        let year = calendar.dateInterval(of: .year, for: date)!
        start = year.start
        let end = min(today, InvestmentBook.addDays(-1, to: year.end))
        // One local replay for the entire year; changing the selected month/day
        // reuses these results and never starts a market data request.
        let gains = book.dailyGains(from: year.start, through: end)
        dailyGains = gains

        func summarize(from start: Date, through end: Date) -> Summary {
            guard let earliest = book.earliest else {
                return Summary(first: nil, last: nil, expectedDays: 0, recordedDays: 0, knownGain: nil)
            }
            let first = max(start, InvestmentBook.day(earliest)), last = min(end, today)
            guard first <= last else {
                return Summary(first: nil, last: nil, expectedDays: 0, recordedDays: 0, knownGain: nil)
            }
            var day = first, expected = 0, recorded = 0, total: Decimal = 0
            while day <= last {
                expected += 1
                if let gain = gains[day] { recorded += 1; total += gain }
                day = InvestmentBook.addDays(1, to: day)
            }
            return Summary(first: first, last: last, expectedDays: expected, recordedDays: recorded,
                           knownGain: recorded > 0 ? total : nil)
        }

        months = (0..<12).map { offset in
            let first = calendar.date(byAdding: .month, value: offset, to: year.start)!
            let next = calendar.date(byAdding: .month, value: 1, to: first)!
            let last = InvestmentBook.addDays(-1, to: next)
            return Month(start: first, end: last, number: offset + 1, summary: summarize(from: first, through: last))
        }
        summary = summarize(from: year.start, through: end)
    }
}
