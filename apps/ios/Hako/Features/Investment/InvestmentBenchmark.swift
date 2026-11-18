import Foundation

enum InvestmentBenchmark: String, CaseIterable, Identifiable, Sendable {
    case sp500 = "标普500", hs300 = "沪深300"
    var id: Self { self }
    var quoteID: String { self == .sp500 ? "100.SPX" : "1.000300" }

    func effectiveDay(session: Date, now: Date) -> Date? {
        let close = self == .sp500 ? InvestmentBook.usEquityClose(on: session)
            : InvestmentBook.calendar.date(bySettingHour: 15, minute: 0, second: 0, of: session)!
        return close <= now ? InvestmentBook.day(close) : nil
    }

    func returns(quotes: [InvestmentQuote], samples: [InvestmentPerformanceSample]) -> [Date: Decimal] {
        let ordered = quotes.filter { $0.isDailyClose == true && $0.price > 0 && !$0.price.isNaN }.sorted { $0.day < $1.day }
        // Both curves share the first funded portfolio closing valuation as baseline.
        guard let first = samples.first(where: { $0.rate != nil }),
              let base = ordered.last(where: { $0.day <= first.day })?.price else { return [:] }
        var cursor = 0
        var price: Decimal?
        var result: [Date: Decimal] = [:]
        for sample in samples where sample.day >= first.day {
            while cursor < ordered.count, ordered[cursor].day <= sample.day { price = ordered[cursor].price; cursor += 1 }
            if let price { result[sample.day] = price / base - 1 }
        }
        return result
    }
}
