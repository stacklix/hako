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
        precondition(snapshot.fields["total_cny"] == "461884.88406188735462735462735462735462", "Viewing cached data must not rewrite it")
        let small = InvestmentCachedRow(table: "investment_events", fields: ["quantity": "0.00123456", "name": "保留名称"], group: "账本")
        precondition(small.displayValue(for: "quantity") == "0.0012")
        precondition(small.displayValue(for: "name") == "保留名称")
        let day = InvestmentBook.day(Date(timeIntervalSince1970: 1_700_000_000))
        let asset = InvestmentAsset(name: "测试", code: "TEST", market: "", kind: .stock, currency: .cny)
        let end = InvestmentBook.addDays(10, to: day), today = InvestmentBook.addDays(20, to: day)
        let quotes = [InvestmentQuote(day: day, price: 10, isDailyClose: true)]
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
