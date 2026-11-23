import Foundation

@main
struct InvestmentPerformanceTests {
    static func day(_ value: Int) -> Date {
        InvestmentBook.calendar.date(from: DateComponents(year: 2026, month: 1, day: value))!
    }
    static func equal(_ actual: Decimal?, _ expected: Decimal, _ message: String = "") {
        precondition(actual.map { abs($0 - expected) < Decimal(string: "0.0000000001")! } == true, message)
    }
    static func sample(_ index: Int, _ value: Decimal?, _ gain: Decimal?, _ flow: Decimal?) -> InvestmentPerformanceSample {
        .init(day: day(index), value: value, gain: gain, flow: flow)
    }
    static func main() throws {
        fundingIsNotPerformance()
        missingDaysNeverRebaseReturns()
        zeroCapitalAndFullExits()
        try accountAndHoldingHistory()
        try transfersAndCurrencyChanges()
        try serverSnapshotGapsStayMissing()
        try overdrawnLedgerRemainsVisible()
        benchmarkSharesThePortfolioBaseline()
        benchmarkClosesUseBeijingDates()
        treemapPreservesAreaAndSign()
        rangeBoundaries()
        print("Investment performance checks passed")
    }
    static func fundingIsNotPerformance() {
        let points = InvestmentPerformanceHistory.normalized([
            sample(1, 1000, 0, 0), sample(2, 2000, 0, 1000), sample(3, 2200, 200, 0), sample(4, 1100, 200, -1100)
        ])
        equal(points[0].rate, 0); equal(points[1].rate, 0); equal(points[2].rate, Decimal(string: "0.1")!)
        equal(points[3].rate, Decimal(string: "0.1")!)
    }
    static func missingDaysNeverRebaseReturns() {
        for gap in [sample(2, nil, nil, 0), sample(2, 1100, 100, nil)] {
            let points = InvestmentPerformanceHistory.normalized([sample(1, 1000, 0, 0), gap, sample(3, 1200, 200, 0)])
            precondition(points[1].rate == nil && points[2].rate == nil)
        }
        let absentStart = InvestmentPerformanceHistory.normalized([sample(1, nil, nil, 0), sample(2, 1200, 200, 0)])
        precondition(absentStart.allSatisfy { $0.rate == nil })
    }
    static func zeroCapitalAndFullExits() {
        let points = InvestmentPerformanceHistory.normalized([
            sample(1, 0, 0, 0), sample(2, 100, 0, 100), sample(3, 0, -100, 0), sample(4, 100, 0, 100)
        ])
        precondition(points[0].rate == nil); equal(points[1].rate, 0); equal(points[2].rate, -1)
        precondition(points[3].rate == nil)
        let sold = InvestmentPerformanceHistory.normalized([sample(1, 100, 0, 0), sample(2, 0, 20, -120), sample(3, 0, 20, 0)])
        equal(sold[1].rate, Decimal(string: "0.2")!); equal(sold[2].rate, Decimal(string: "0.2")!)
    }
    static func accountAndHoldingHistory() throws {
        let account = InvestmentAccount(name: "证券", currency: .cny, type: .securities)
        var book = InvestmentBook(accounts: [account])
        let id = try book.register(.init(name: "股票", code: "600000.SH", market: "", kind: .stock, currency: .cny))
        try book.post(.init(day: day(1), kind: .deposit, amount: 1000), accountID: account.id)
        try book.post(.init(day: day(1), kind: .buy, assetID: id, quantity: 100, price: 5), accountID: account.id)
        try book.post(.init(day: day(3), kind: .deposit, amount: 1000), accountID: account.id)
        try book.post(.init(day: day(4), kind: .sell, assetID: id, quantity: 100, price: 7), accountID: account.id)
        try book.post(.init(day: day(5), kind: .withdrawal, amount: -1000), accountID: account.id)
        book.addQuotes([.init(day: day(1), price: 5, isDailyClose: true), .init(day: day(2), price: 6, isDailyClose: true),
                        .init(day: day(3), price: 7, isDailyClose: true)], assetID: id)
        let history = book.performanceHistory(accountID: account.id, from: day(1), through: day(5))
        equal(history.samples.last?.value, 1200); equal(history.samples.last?.gain, 200)
        equal(history.samples.last?.rate, Decimal(string: "0.2")!)
        let details = history.categories.compactMap { $0.detail(on: day(5)) }
        equal(details.reduce(Decimal.zero) { $0 + ($1.value ?? 0) }, 1200)
        equal(details.reduce(Decimal.zero) { $0 + ($1.periodGain ?? 0) }, 200)
        let stock = details.first { $0.assetID == id }!
        equal(stock.value, 0); equal(stock.periodGain, 200); equal(stock.rate, Decimal(string: "0.4")!)
        let partial = history.categories.first { $0.assetID == id }!.detail(on: day(2))!
        equal(partial.value, 600); equal(partial.periodGain, 100)
    }
    static func transfersAndCurrencyChanges() throws {
        let first = InvestmentAccount(name: "一", currency: .cny, type: .securities)
        let second = InvestmentAccount(name: "二", currency: .cny, type: .securities)
        var book = InvestmentBook(accounts: [first, second])
        try book.post(.init(day: day(1), kind: .deposit, amount: 1000), accountID: first.id)
        try book.transfer(from: first.id, to: second.id, amount: 400, remaining: 600, on: day(2))
        let history = book.performanceHistory(from: day(1), through: day(3))
        equal(history.samples.last?.value, 1000); equal(history.samples[1].flow, 0); equal(history.samples.last?.rate, 0)
        let usd = InvestmentAccount(name: "美元", currency: .usd, type: .securities)
        var foreign = InvestmentBook(accounts: [usd])
        try foreign.post(.init(day: day(1), kind: .deposit, amount: 100), accountID: usd.id)
        foreign.fx[.usd] = [.init(day: day(1), price: 7, isDailyClose: true), .init(day: day(2), price: 8, isDailyClose: true)]
        let converted = foreign.performanceHistory(from: day(1), through: day(2))
        equal(converted.samples.last?.value, 800); equal(converted.samples.last?.flow, 0)
        equal(converted.samples.last?.rate, Decimal(8) / 7 - 1)
    }
    static func serverSnapshotGapsStayMissing() throws {
        let account = InvestmentAccount(name: "日终", currency: .cny, type: .securities)
        let empty = InvestmentAccount(name: "空账户", currency: .cny, type: .securities)
        var book = InvestmentBook(accounts: [account, empty])
        try book.post(.init(day: day(1), kind: .deposit, amount: 100), accountID: account.id)
        book.usesServerSnapshots = true
        book.dailySnapshots = .init(through: day(3), values: [day(1): .init(value: 100, gain: 0), day(3): .init(value: 100, gain: 0)],
            accountValues: [account.id: [day(1): .init(cash: 100, holdings: 0, gain: 0), day(3): .init(cash: 100, holdings: 0, gain: 0)]])
        let history = book.performanceHistory(from: day(1), through: day(4))
        precondition(history.samples[1].value == nil && history.samples[2].rate == nil)
        equal(history.categories.first { $0.id == empty.id.uuidString }?.samples[1].value, 0)
        let scoped = book.performanceHistory(accountID: account.id, from: day(1), through: day(4))
        precondition(scoped.samples[1].value == nil && scoped.samples[2].rate == nil)
    }
    static func benchmarkSharesThePortfolioBaseline() {
        let samples = InvestmentPerformanceHistory.normalized([sample(1, 100, 0, 0),sample(2, 120, 20, 0),sample(3, 125, 25, 0)])
        let quotes: [InvestmentQuote] = [.init(day: day(1), price: 100, isDailyClose: true),
                                        .init(day: day(3), price: 110, isDailyClose: true), .init(day: day(4), price: 500, isDailyClose: true)]
        let result = InvestmentBenchmark.sp500.returns(quotes: quotes, samples: samples)
        equal(result[day(1)], 0); equal(result[day(2)], 0); equal(result[day(3)], Decimal(string: "0.1")!)
        precondition(InvestmentBenchmark.sp500.returns(quotes: Array(quotes.dropFirst()), samples: samples).isEmpty)
    }
    static func overdrawnLedgerRemainsVisible() throws {
        let account = InvestmentAccount(name: "错误记录", currency: .cny, type: .securities)
        var book = InvestmentBook(accounts: [account])
        try book.post(.init(day: day(1), kind: .deposit, amount: 100), accountID: account.id)
        book.accounts[0].events.append(.init(day: day(2), kind: .withdrawal, amount: -1000))
        let history = book.performanceHistory(from: day(1), through: day(4))
        precondition(history.samples.count == 4 && history.samples.last?.value == -900)
        precondition(history.categories[0].detail(on: day(4))?.periodGain == 0,
                     "A negative cash balance should remain visible, without being treated as a trading loss")
    }
    static func benchmarkClosesUseBeijingDates() {
        let session = InvestmentBook.calendar.date(from: DateComponents(year: 2026, month: 11, day: 17))!
        let next = InvestmentBook.addDays(1, to: session)
        precondition(InvestmentBenchmark.sp500.effectiveDay(session: session, now: next.addingTimeInterval(6*3600)) == next)
        precondition(InvestmentBenchmark.sp500.effectiveDay(session: session, now: next.addingTimeInterval(4*3600)) == nil)
        precondition(InvestmentBenchmark.hs300.effectiveDay(session: session, now: session.addingTimeInterval(14*3600)) == nil)
        precondition(InvestmentBenchmark.hs300.effectiveDay(session: session, now: session.addingTimeInterval(15*3600)) == session)
    }
    static func treemapPreservesAreaAndSign() {
        let rectangles = InvestmentProfitRectangle.layout([("a",100),("b",-50),("cash",0)], width: 300, height: 200)
        precondition(rectangles.count == 2)
        for rectangle in rectangles {
            precondition(abs(rectangle.width*rectangle.height/(300*200)-NSDecimalNumber(decimal: abs(rectangle.amount)/150).doubleValue) < 0.000001)
            precondition(rectangle.x >= 0 && rectangle.y >= 0 && rectangle.x+rectangle.width <= 300.000001 && rectangle.y+rectangle.height <= 200.000001)
        }
        precondition(InvestmentProfitRectangle.layout([("zero",0)],width:300,height:200).isEmpty)
    }
    static func rangeBoundaries() {
        let now = InvestmentBook.calendar.date(from: DateComponents(year: 2026, month: 11, day: 18))!
        let first = day(1)
        precondition(InvestmentHistoryRange.trend.map(\.rawValue) == ["今年","近一月","近三月","近半年","近一年","近两年","近五年"])
        precondition(InvestmentHistoryRange.yearToDate.start(through: now, firstEntry: first) == first)
    }
}
