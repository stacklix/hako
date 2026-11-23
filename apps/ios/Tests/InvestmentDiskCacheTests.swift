import Foundation

@main struct InvestmentDiskCacheTests {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = InvestmentDiskCache(directory: directory)
        let fx = ["rate_date": "2026-10-30", "base_currency": "USD", "quote_currency": "CNY", "rate": "7.123456789012345678"]
        let state = InvestmentServerState(generation: 9, revision: 3, tables: ["market_daily_fx": [fx]])
        try await cache.save(state, scope: "account-a")
        let reopened = InvestmentDiskCache(directory: directory)
        let loaded = try await reopened.load(scope: "account-a")
        precondition(loaded?.generation == 9 && loaded?.tables["market_daily_fx"] == [fx])
        let other = try await reopened.load(scope: "account-b")
        precondition(other == nil, "Disk caches must be isolated by server/account scope")
        let rows = InvestmentDataCategory.rates.rows(in: state)
        precondition(rows.count == 1 && rows[0].group == "USD / CNY")
        precondition(rows[0].value == "7.1235")
        let snapshot = InvestmentCachedRow(table: "investment_daily_snapshots", fields: ["total_cny": "461884.88406188735462735462735462735462"], group: "全部投资账户")
        precondition(snapshot.value == "461884.88")
        let whole = InvestmentCachedRow(table: "investment_account_daily_snapshots", fields: ["holdings_native": "330000"], group: "账户")
        precondition(whole.value == "330000.00")
        precondition(snapshot.fields["total_cny"] == "461884.88406188735462735462735462735462", "Viewing cached data must not rewrite it")
        let small = InvestmentCachedRow(table: "investment_events", fields: ["quantity": "0.00123456", "name": "保留名称"], group: "账本")
        precondition(small.displayValue(for: "quantity") == "0.00123456")
        precondition(small.displayValue(for: "name") == "保留名称")
        let trade = InvestmentCachedRow(table: "investment_events", fields: ["unit_price": "12.3456", "amount": "12.3456"], group: "账本")
        precondition(trade.displayValue(for: "unit_price") == "12.3456")
        precondition(trade.displayValue(for: "amount") == "12.35")
        let quote = InvestmentCachedRow(table: "market_daily_prices", fields: ["price": "1.2345"], group: "行情")
        precondition(quote.value == "1.2345")
        let day = InvestmentBook.day(Date(timeIntervalSince1970: 1_700_000_000))
        let asset = InvestmentAsset(name: "测试", code: "TEST", market: "", kind: .stock, currency: .cny)
        let end = InvestmentBook.addDays(10, to: day), today = InvestmentBook.addDays(20, to: day)
        let quotes = [InvestmentQuote(day: day, price: 10, isDailyClose: true)]
        // Missing dates inside a series must not cause existing dates to be re-queried.
        let gap = InvestmentBook.addDays(1, to: day), third = InvestmentBook.addDays(2, to: day)
        let observations = quotes + [InvestmentQuote(day: third, price: 12, isDailyClose: true)]
        let gaps = InvestmentHistoryRange.missingWindows(from: day, through: third,
            observations: observations, covered: [])
        precondition(gaps == [gap...gap])
        try await reopened.saveHistory(scope: "pending", asset: asset, start: gap, end: gap, today: today, quotes: [])
        let restart = InvestmentDiskCache(directory: directory)
        let coveredGap = try await restart.missingWindows(scope: "pending", key: InvestmentDiskCache.historyKey(asset),
            start: day, end: third, today: today, observations: observations)
        precondition(coveredGap.isEmpty, "Successful empty holiday responses must survive restarts")
        // Download first, retain it when the server has not acknowledged a write.
        try await restart.saveHistory(scope: "pending", asset: asset, start: day, end: day, today: today, quotes: quotes)
        let unconfirmed = try await reopened.marketQuotes(scope: "pending", key: InvestmentDiskCache.historyKey(asset))
        let noLedger = try await reopened.load(scope: "pending")
        precondition(unconfirmed == quotes && noLedger == nil, "Only market observations may be pending locally; never invent a confirmed ledger")
        try await reopened.save(state, scope: "pending")
        let afterServerSync = try await restart.missingWindows(scope: "pending", key: InvestmentDiskCache.historyKey(asset),
            start: day, end: third, today: today, observations: observations)
        precondition(afterServerSync.isEmpty, "Server reads and successful writes must not discard query coverage")
        let rateKey = InvestmentDiskCache.rateKey(.usd)
        try await restart.saveMarketHistory(scope: "pending", key: rateKey, start: day, end: third, today: today, quotes: quotes)
        let fxHit = try await reopened.missingWindows(scope: "pending", key: rateKey, start: day, end: third, today: today, observations: [])
        precondition(fxHit.isEmpty, "FX history and empty dates must persist independently of asset history")
        let next = InvestmentBook.addDays(1, to: third)
        let newDayOnly = try await reopened.missingWindows(scope: "pending", key: rateKey, start: day, end: next, today: today, observations: [])
        precondition(newDayOnly == [next...next], "Refreshes may request only the new uncovered suffix")
        try await restart.saveMarketHistory(scope: "current", key: rateKey, start: today, end: today, today: today, quotes: [])
        let sameDay = try await reopened.missingWindows(scope: "current", key: rateKey, start: today, end: today, today: today, observations: [])
        let followingDay = try await reopened.missingWindows(scope: "current", key: rateKey, start: today, end: today,
            today: InvestmentBook.addDays(1, to: today), observations: [])
        precondition(sameDay.isEmpty && followingDay == [today...today], "An unpublished current day is not a permanent holiday")
        try await reopened.saveHistory(scope: "account-a", asset: asset, start: day, end: end, today: today, quotes: quotes)
        let history = try await cache.history(scope: "account-a", asset: asset, start: day, end: end, today: today)
        precondition(history?.first?.price == 10, "Historical coverage must survive process restarts and missing market dates")
        let absent = try await cache.history(scope: "account-a", asset: asset, start: day, end: today, today: today)
        precondition(absent == nil, "An uncovered suffix must reach the server before the API")
        try await cache.remove(scope: "account-a", category: .rates, rows: rows)
        let incomplete = try await cache.load(scope: "account-a")
        let view = try await cache.snapshot(scope: "account-a")
        precondition(incomplete == nil && view?.tables["market_daily_fx"]?.isEmpty == true)
        precondition(state.tables["market_daily_fx"] == [fx], "Evicting disk rows must not mutate server records")
        try await cache.save(state, scope: "account-a")
        try await cache.remove(scope: "account-a")
        let cleared = try await cache.snapshot(scope: "account-a")
        precondition(cleared == nil)
        precondition(InvestmentHistoryRange.uncoveredWindows(from: day, through: end, cached: quotes) == [InvestmentBook.addDays(1, to: day)...end])
        do { _ = try await cache.load(scope: "../outside"); preconditionFailure("Unsafe scope accepted") }
        catch is CocoaError {}
        print("Investment disk cache: persistence, precision, scope isolation, range coverage, eviction and server fallback passed")
    }
}
