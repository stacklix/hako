import Foundation

@main struct InvestmentPriceHistoryTests {
    static func day(_ text: String) -> Date { InvestmentBook.snapshotDateFormatter().date(from: text)! }

    static func main() throws {
        rangesKeepMarketHistoryBeforeThePosition()
        everyHoldingHasProfitAndSharedRanges()
        queryWindowsCoverEveryDayOnce()
        marketClosesExcludeEstimatesAndFutureDates()
        usClosesUseBeijingDates()
        tradesStayInTheirAccountAndKeepExecutionPrices()
        print("Investment price history checks passed")
        print("Investment price history: ranges, batching, final closes, Beijing dates and transaction points passed")
    }

    static func everyHoldingHasProfitAndSharedRanges() {
        precondition(InvestmentHistoryRange.allCases.count == 7)
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
