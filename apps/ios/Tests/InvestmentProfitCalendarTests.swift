import Foundation

@main
struct InvestmentProfitCalendarTests {
    static func main() throws {
        partialFirstAndCurrentMonths()
        missingDaysNeverBecomeZero()
        zeroGainIsACompleteRecord()
        yearsAndLeapDaysStaySeparate()
        emptyAndFuturePeriodsStayEmpty()
        try cashFlowsDoNotBecomeMonthlyProfit()
        print("Profit calendar: daily/monthly/yearly totals, partial periods, missing snapshots, zero gains, leap years, year boundaries and cash-flow exclusion passed")
    }

    static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        InvestmentBook.calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    static func fixture(from first: Date, through last: Date, gains: [Date: Decimal] = [:]) -> InvestmentBook {
        var account = InvestmentAccount(name: "月历测试", currency: .cny, type: .securities)
        account.events = [.init(day: first, kind: .deposit, amount: 100)]
        var values: [Date: InvestmentValuation] = [:], cumulative: Decimal = 0, date = first
        while date <= last {
            cumulative += gains[date] ?? 0
            values[date] = .init(value: 100 + cumulative, gain: cumulative)
            date = InvestmentBook.addDays(1, to: date)
        }
        var book = InvestmentBook(accounts: [account])
        book.usesServerSnapshots = true
        book.dailySnapshots = .init(through: last, values: values, hasUSD: true)
        return book
    }

    static func partialFirstAndCurrentMonths() {
        let first = day(2024, 11, 16), today = day(2024, 11, 24)
        let gains: [Date: Decimal] = [first: -6900, day(2024, 11, 17): 3400, day(2024, 11, 18): Decimal(string: "-46.2")!,
            day(2024, 11, 19): Decimal(string: "0.3")!, day(2024, 11, 20): -6200, day(2024, 11, 21): -16,
            day(2024, 11, 22): Decimal(string: "4.8")!, day(2024, 11, 23): -3600, today: Decimal(string: "11957.47")!]
        let data = InvestmentProfitCalendarData(book: fixture(from: first, through: today, gains: gains), yearContaining: today, today: today)
        precondition(data.months.count == 12 && data.months.map(\.number) == Array(1...12))
        precondition(data.months.prefix(10).allSatisfy { $0.summary.gain == nil && $0.summary.expectedDays == 0 })
        let november = data.months[10].summary
        precondition(november.first == first && november.last == today && november.expectedDays == 9 && november.recordedDays == 9)
        precondition(november.gain == Decimal(string: "-1399.63")! && data.summary.gain == november.gain)
        precondition(data.dailyGains == gains && data.dailyGains[today] == Decimal(string: "11957.47")!)
        precondition(data.months[11].summary.gain == nil && data.months[11].summary.expectedDays == 0)
    }

    static func missingDaysNeverBecomeZero() {
        let first = day(2024, 11, 16), today = day(2024, 11, 24)
        var book = fixture(from: first, through: today, gains: [first: 10, day(2024, 11, 18): 2, day(2024, 11, 19): 3, today: 20])
        book.dailySnapshots!.values.removeValue(forKey: day(2024, 11, 18))
        let data = InvestmentProfitCalendarData(book: book, yearContaining: today, today: today)
        let month = data.months[10].summary
        precondition(month.expectedDays == 9 && month.recordedDays == 7 && month.missingDays == 2)
        precondition(month.gain == nil && month.knownGain == 30 && data.summary.gain == nil)
        precondition(data.dailyGains[day(2024, 11, 18)] == nil && data.dailyGains[day(2024, 11, 19)] == nil,
                     "A missing snapshot and the following daily delta must not be invented")
        book.dailySnapshots!.values.removeValue(forKey: first)
        let missingFirst = InvestmentProfitCalendarData(book: book, yearContaining: today, today: today)
        precondition(missingFirst.dailyGains[first] == nil && missingFirst.months[10].summary.gain == nil)
    }

    static func zeroGainIsACompleteRecord() {
        let first = day(2024, 2, 1), today = day(2024, 2, 29)
        let data = InvestmentProfitCalendarData(book: fixture(from: first, through: today), yearContaining: today, today: today)
        precondition(data.months[1].summary.expectedDays == 29 && data.months[1].summary.recordedDays == 29)
        precondition(data.months[1].summary.gain == 0 && data.summary.gain == 0)
        precondition(data.months[0].summary.gain == nil && data.months[2].summary.gain == nil)
    }

    static func yearsAndLeapDaysStaySeparate() {
        let first = day(2023, 12, 31), today = day(2024, 3, 1)
        let book = fixture(from: first, through: today, gains: [first: 100, day(2024, 1, 1): 5, day(2024, 2, 29): -2, today: 3])
        let current = InvestmentProfitCalendarData(book: book, yearContaining: today, today: today)
        precondition(current.start == day(2024, 1, 1) && current.summary.expectedDays == 61)
        precondition(current.months[0].summary.gain == 5 && current.months[1].summary.gain == -2 && current.months[2].summary.gain == 3)
        precondition(current.summary.gain == 6 && current.months[1].end == day(2024, 2, 29))
        let previous = InvestmentProfitCalendarData(book: book, yearContaining: first, today: today)
        precondition(previous.summary.gain == 100 && previous.summary.expectedDays == 1)
        precondition(previous.months[11].summary.last == first && previous.dailyGains[today] == nil)
    }

    static func emptyAndFuturePeriodsStayEmpty() {
        let today = day(2024, 11, 24)
        let empty = InvestmentProfitCalendarData(book: InvestmentBook(), yearContaining: today, today: today)
        precondition(empty.months.count == 12 && empty.summary.gain == nil && empty.dailyGains.isEmpty)
        let future = InvestmentProfitCalendarData(book: fixture(from: today, through: today), yearContaining: day(2025, 1, 1), today: today)
        precondition(future.months.allSatisfy { $0.summary.expectedDays == 0 && $0.summary.gain == nil })
    }

    static func cashFlowsDoNotBecomeMonthlyProfit() throws {
        let first = day(2024, 1, 1), secondMonth = day(2024, 2, 1), today = day(2024, 2, 2)
        let account = InvestmentAccount(name: "现金流测试", currency: .cny, type: .securities)
        var book = InvestmentBook(accounts: [account])
        let stock = try book.register(.init(name: "测试股票", code: "600000", market: "XSHG", kind: .stock, currency: .cny))
        try book.post(.init(day: first, kind: .deposit, amount: 100), accountID: account.id)
        try book.post(.init(day: first, kind: .buy, assetID: stock, quantity: 10, price: 2), accountID: account.id)
        try book.post(.init(day: day(2024, 1, 20), kind: .withdrawal, amount: -50), accountID: account.id)
        try book.post(.init(day: secondMonth, kind: .deposit, amount: 200), accountID: account.id)
        book.addQuotes([.init(day: first, price: 3, isDailyClose: true), .init(day: secondMonth, price: 4, isDailyClose: true)], assetID: stock)
        let data = InvestmentProfitCalendarData(book: book, yearContaining: today, today: today)
        precondition(data.months[0].summary.gain == 10 && data.months[1].summary.gain == 10 && data.summary.gain == 20)
        precondition(data.dailyGains[day(2024, 1, 20)] == 0 && data.dailyGains[secondMonth] == 10,
                     "Deposits and withdrawals must not be mistaken for investment profit")
    }
}
