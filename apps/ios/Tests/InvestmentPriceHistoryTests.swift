import Foundation

@main struct InvestmentPriceHistoryTests {
    static func day(_ text: String) -> Date { InvestmentBook.snapshotDateFormatter().date(from: text)! }

    static func main() throws {
        rangesKeepMarketHistoryBeforeThePosition()
        everyHoldingHasProfitAndSharedRanges()
        queryWindowsCoverEveryDayOnce()
        holidayGapsShareRequests()
        forexWeekendsUseWorkingDayRates()
        automaticHistoryUsesEachAssetsOwnStart()
        marketClosesExcludeEstimatesAndFutureDates()
        usClosesUseBeijingDates()
        tradesStayInTheirAccountAndKeepExecutionPrices()
        print("Investment price history checks passed")
        print("Investment price history: ranges, batching, final closes, Beijing dates and transaction points passed")
    }

    static func everyHoldingHasProfitAndSharedRanges() {
        precondition(InvestmentHistoryRange.allCases.count == 8)
        precondition(InvestmentHistoryRange.trend.count == 7)
        for kind in InvestmentKind.allCases {
            let asset = InvestmentAsset(name: "测试", code: "TEST", market: "", kind: kind, currency: .cny)
            let expected: [InvestmentHoldingChartDisplay] = [.stock, .fund, .etf, .crypto].contains(kind)
                ? [.price, .holding, .profit] : [.holding, .profit]
            precondition(asset.holdingChartDisplays == expected, "Every holding needs a profit tab, including deposits and certificates")
        }
    }

    static func rangesKeepMarketHistoryBeforeThePosition() {
        let today = day("2026-11-17"), first = day("2026-09-04")
        precondition(InvestmentHistoryRange.all.start(through: today, firstEntry: first) == first)
        precondition(InvestmentHistoryRange.yearToDate.start(through: today, firstEntry: first) == day("2026-01-01"))
        for (range, expected) in [(InvestmentHistoryRange.month, "2026-10-17"), (.quarter, "2026-08-17"),
                                  (.half, "2026-05-17"), (.year, "2025-11-17"), (.twoYears, "2024-11-17"), (.fiveYears, "2021-11-17")] {
            precondition(range.start(through: today, firstEntry: first) == day(expected))
        }
        precondition(InvestmentHistoryRange.month.start(through: day("2024-03-31"), firstEntry: first) == day("2024-02-29"))
    }

    static func queryWindowsCoverEveryDayOnce() {
        let first = day("2021-11-17"), end = day("2026-11-17")
        let windows = InvestmentHistoryRange.quoteWindows(from: first, through: end)
        precondition(windows.first?.lowerBound == first && windows.last?.upperBound == end)
        for (index, window) in windows.enumerated() {
            precondition(window.upperBound <= InvestmentBook.addDays(364, to: window.lowerBound))
            if index > 0 { precondition(window.lowerBound == InvestmentBook.addDays(1, to: windows[index - 1].upperBound)) }
        }
        precondition(InvestmentHistoryRange.quoteWindows(from: end, through: end) == [end...end])
        precondition(InvestmentHistoryRange.quoteWindows(from: end, through: first).isEmpty)
    }

    static func holidayGapsShareRequests() {
        let first = day("2025-01-01")
        let weekends = stride(from: 3, to: 360, by: 7).map { offset in
            InvestmentBook.addDays(offset, to: first)...InvestmentBook.addDays(offset + 1, to: first)
        }
        let windows = InvestmentHistoryRange.quoteWindows(for: weekends)
        precondition(windows.count == 1 && windows[0].lowerBound == weekends[0].lowerBound && windows[0].upperBound == weekends.last!.upperBound,
                     "A year's scattered weekends must use one complete range request")
        precondition(InvestmentHistoryRange.quoteWindows(for: []).isEmpty)
        let distant = InvestmentBook.addDays(900, to: first)
        precondition(InvestmentHistoryRange.quoteWindows(for: [first...first, distant...distant]).count == 2,
                     "Widely separated gaps do not force downloads of all intervening years")
    }

    static func forexWeekendsUseWorkingDayRates() {
        let thursday = day("2025-07-10"), friday = day("2025-07-11")
        let saturday = day("2025-07-12"), sunday = day("2025-07-13"), monday = day("2025-07-14")
        precondition(InvestmentHistoryRange.forexQuoteWindows(for: [saturday...sunday]).isEmpty)
        precondition(InvestmentHistoryRange.forexQuoteWindows(for: [sunday...sunday]).isEmpty)
        precondition(InvestmentHistoryRange.forexQuoteWindows(for: [friday...sunday]) == [friday...friday])
        precondition(InvestmentHistoryRange.forexQuoteWindows(for: [saturday...monday]) == [monday...monday])
        let normalized = InvestmentBook.weekdayMarketDate(on: sunday)
        precondition(normalized == friday)
        let rate = InvestmentQuote(day: friday, price: 7, isDailyClose: true)
        let known = InvestmentHistoryRange.missingWindows(from: normalized, through: normalized, observations: [rate], covered: [])
        precondition(InvestmentHistoryRange.forexQuoteWindows(for: known).isEmpty,
                     "A cached Friday rate must not trigger any Sunday request")
        let missing = InvestmentHistoryRange.missingWindows(from: normalized, through: normalized, observations: [], covered: [])
        precondition(InvestmentHistoryRange.forexQuoteWindows(for: missing) == [friday...friday],
                     "Without a cached rate, query the previous working day rather than Sunday")
        var book = InvestmentBook()
        book.fx[.usd] = [rate]
        precondition(book.rateToCNY(.usd, on: saturday, requiresDailyPrice: true) == 7)
        precondition(book.rateToCNY(.usd, on: sunday, requiresDailyPrice: true) == 7)
        book.fx[.usd] = [.init(day: thursday, price: 6, isDailyClose: true)]
        precondition(book.rateToCNY(.usd, on: sunday, requiresDailyPrice: true) == 6,
                     "When Friday has no published observation, retain the most recent earlier valid rate")
        precondition(book.fx[.usd]?.count == 1, "Weekend valuation must not invent a dated FX observation")
        let yearly = InvestmentHistoryRange.forexQuoteWindows(for: [day("2024-01-01")...sunday])
        precondition(yearly.allSatisfy {
            ![1, 7].contains(InvestmentBook.calendar.component(.weekday, from: $0.lowerBound)) &&
            ![1, 7].contains(InvestmentBook.calendar.component(.weekday, from: $0.upperBound))
        })
    }

    static func automaticHistoryUsesEachAssetsOwnStart() {
        let today = day("2026-11-24")
        let recent = InvestmentAsset(name: "新持仓", code: "AAPL", market: "XNAS", kind: .stock, currency: .usd)
        let old = InvestmentAsset(name: "旧持仓", code: "MSFT", market: "XNAS", kind: .stock, currency: .usd)
        let watch = InvestmentAsset(name: "只关注", code: "SPYM", market: "ARCX", kind: .etf, currency: .usd)
        let account = InvestmentAccount(name: "测试", currency: .usd, events: [
            .init(day: day("2015-01-01"), kind: .deposit, amount: 1000),
            .init(day: day("2025-01-01"), kind: .opening, assetID: old.id, quantity: 1, price: 10),
            .init(day: today, kind: .buy, assetID: recent.id, quantity: 1, price: 10)
        ], type: .securities)
        let book = InvestmentBook(accounts: [account])
        precondition(book.automaticQuoteWindow(for: recent.id, through: today) == day("2026-11-10")...today,
                     "A new holding must not inherit another account's ten-year history")
        precondition(book.automaticQuoteWindow(for: old.id, through: today) == day("2024-12-31")...today)
        precondition(book.automaticQuoteWindow(for: watch.id, through: today) == day("2026-11-10")...today)
    }

    static func marketClosesExcludeEstimatesAndFutureDates() {
        for kind in [InvestmentKind.fund, .stock, .etf, .crypto] {
            let asset = InvestmentAsset(name: "测试", code: "TEST", market: "", kind: kind, currency: .cny)
            let first = day("2026-11-13"), last = day("2026-11-17")
            let cache: [InvestmentQuote] = [
                .init(day: first, price: 2, source: "行情", isDailyClose: true),
                .init(day: day("2026-11-14"), price: 99, source: "手动录入", isDailyClose: true),
                .init(day: day("2026-11-15"), price: 5, source: "盘中", isDailyClose: false),
                .init(day: day("2026-11-16"), price: 0, source: "行情", isDailyClose: true),
            ]
            let fetched: [InvestmentQuote] = [
                .init(day: first, price: 3, source: "行情", isDailyClose: true),
                .init(day: last, price: 4, source: "行情", isDailyClose: true),
                .init(day: day("2026-11-18"), price: 5, source: "行情", isDailyClose: true),
            ]
            let series = InvestmentBook.priceHistory(asset: asset, cached: cache, fetched: fetched, in: first...last)
            precondition(series.map(\.day) == [first, last] && series.map(\.price) == [3, 4])
        }
        let wealth = InvestmentAsset(name: "理财", code: "理财", market: "", kind: .wealth, currency: .cny)
        precondition(!wealth.supportsPriceHistory)
    }

    static func usClosesUseBeijingDates() {
        let asset = InvestmentAsset(name: "美股", code: "AAPL", market: "XNAS", kind: .stock, currency: .usd)
        let saturday = day("2026-11-14")
        let series = InvestmentBook.priceHistory(asset: asset, cached: [], fetched: [
            .init(day: day("2026-11-13"), price: 200, source: "行情", isDailyClose: true),
            .init(day: saturday, price: 201, source: "行情", isDailyClose: true),
        ], in: saturday...saturday)
        precondition(series.count == 1 && series[0].day == saturday && series[0].price == 200)
    }

    static func tradesStayInTheirAccountAndKeepExecutionPrices() {
        let asset = InvestmentAsset(name: "港股通", code: "00700.HK", market: InvestmentAsset.stockConnectMarket, kind: .stock, currency: .hkd)
        let first = day("2026-09-04"), last = day("2026-11-17")
        let opening = InvestmentEvent(day: first, kind: .opening, assetID: asset.id, quantity: 100, price: 350)
        let buy = InvestmentEvent(day: last, kind: .buy, assetID: asset.id, quantity: 200, price: 399)
        let sell = InvestmentEvent(day: last, kind: .sell, assetID: asset.id, quantity: 50, price: 405)
        let account = InvestmentAccount(name: "人民币证券", currency: .cny, events: [
            .init(day: day("2026-08-01"), kind: .deposit, amount: 100000), opening, buy, sell,
            .init(day: last, kind: .dividend, assetID: asset.id, amount: 20),
            .init(day: last, kind: .bonusShares, assetID: asset.id, quantity: 10),
            .init(day: last, kind: .buy, assetID: UUID(), quantity: 1, price: 99),
            .init(day: day("2026-11-18"), kind: .buy, assetID: asset.id, quantity: 100, price: 410),
        ], type: .securities)
        let other = InvestmentAccount(name: "另一账户", currency: .cny, events: [buy], type: .securities)
        let book = InvestmentBook(accounts: [account, other], assets: [asset.id: asset])
        precondition(book.firstPositionDay(accountID: account.id, assetID: asset.id) == first)
        let trades = book.priceTrades(accountID: account.id, assetID: asset.id, in: first...last)
        precondition(trades.map(\.id) == [opening.id, buy.id, sell.id])
        precondition(trades.map(\.price) == [350, 399, 405] && trades.map(\.quantity) == [100, 200, 50])
        precondition(trades.map(\.isBuy) == [true, true, false] && trades[0].isOpening)
        precondition(book.priceTrades(accountID: UUID(), assetID: asset.id, in: first...last).isEmpty)

        let crypto = InvestmentAsset(name: "Bitcoin", code: "BTC", market: "BINANCE", kind: .crypto, currency: .usd)
        let cryptoBuy = InvestmentEvent(day: first, kind: .buy, assetID: crypto.id, quantity: Decimal(string: "0.002")!, price: 65000)
        let cryptoSell = InvestmentEvent(day: last, kind: .sell, assetID: crypto.id, quantity: Decimal(string: "0.001")!, price: 98000)
        let wallet = InvestmentAccount(name: "Spot", currency: .usd, events: [cryptoBuy, cryptoSell], type: .crypto)
        let cryptoBook = InvestmentBook(accounts: [wallet], assets: [crypto.id: crypto])
        precondition(crypto.supportsPriceHistory)
        precondition(cryptoBook.firstPositionDay(accountID: wallet.id, assetID: crypto.id) == first)
        let cryptoTrades = cryptoBook.priceTrades(accountID: wallet.id, assetID: crypto.id, in: first...last)
        precondition(cryptoTrades.map(\.price) == [65000, 98000] && cryptoTrades.map(\.isBuy) == [true, false])
        precondition(cryptoTrades.map(\.quantity) == [Decimal(string: "0.002")!, Decimal(string: "0.001")!])
    }
}
