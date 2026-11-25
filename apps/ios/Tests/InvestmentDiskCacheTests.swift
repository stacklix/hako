import Foundation

private final class MarketReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func read(_ url: URL) throws -> Data {
        lock.lock(); count += 1; lock.unlock()
        return try Data(contentsOf: url)
    }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func reset() { lock.lock(); count = 0; lock.unlock() }
}

@main struct InvestmentDiskCacheTests {
    static func main() async throws {
        try await publishedFundNAVRetriesAfterDelay()
        try await provisionalFXRefreshesDespiteCoverage()
        try await dailyCryptoSpotReuse()
        try await refreshReadsMarketCacheOnce()
        try await closingQuoteOverridesPreCloseCoverage()
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


    static func publishedFundNAVRetriesAfterDelay() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = InvestmentDiskCache(directory: directory)
        let today = InvestmentBook.day(), first = InvestmentBook.addDays(-3, to: today)
        let end = InvestmentBook.addDays(-1, to: today)
        let fund = InvestmentAsset(name: "QDII", code: "017302.OF", market: "OF", kind: .fund, currency: .cny)
        let key = InvestmentDiskCache.historyKey(fund)
        let quote = InvestmentQuote(day: first, price: Decimal(string: "1.2345")!, isDailyClose: true)
        try await cache.saveHistory(scope: "nav", asset: fund, start: first, end: end, today: today, quotes: [quote])
        let current = try await cache.marketReadSnapshot(scope: "nav")
        precondition(current.missingWindows(key: key, start: first, end: end, today: today, observations: [quote], requiredClose: end, publishedNAV: true).isEmpty,
                     "A missing NAV must not defeat the short retry cooldown")
        let expired = try await cache.marketReadSnapshot(scope: "nav", now: Date.now.addingTimeInterval(901))
        precondition(expired.missingWindows(key: key, start: first, end: end, today: today, observations: [quote], publishedNAV: true) == [InvestmentBook.addDays(1, to: first)...end],
                     "Published NAV coverage cannot permanently hide a late QDII tail")
        let reopened = try await InvestmentDiskCache(directory: directory).marketReadSnapshot(scope: "nav")
        precondition(!reopened.missingWindows(key: key, start: first, end: end, today: today, observations: [quote], publishedNAV: true).isEmpty,
                     "Restarting must not turn an unpublished NAV into a permanent holiday")
        let holiday = InvestmentBook.addDays(-1, to: first)
        try await cache.saveHistory(scope: "nav", asset: fund, start: holiday, end: holiday, today: today, quotes: [])
        let historical = try await InvestmentDiskCache(directory: directory).marketReadSnapshot(scope: "nav")
        precondition(historical.missingWindows(key: key, start: holiday, end: holiday, today: today, observations: [quote], publishedNAV: true).isEmpty,
                     "An empty historical holiday before a published NAV must stay reusable")
        let late = InvestmentQuote(day: end, price: Decimal(string: "1.3456")!, isDailyClose: true)
        try await cache.saveHistory(scope: "nav", asset: fund, start: InvestmentBook.addDays(1, to: first), end: end, today: today, quotes: [late])
        let saved = try await cache.marketQuotes(scope: "nav", key: key)
        precondition(saved.first?.day == first && saved.last?.day == end && saved.last?.price == late.price)
    }

    static func closingQuoteOverridesPreCloseCoverage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = InvestmentDiskCache(directory: directory)
        let today = InvestmentBook.day()
        let session = InvestmentBook.addDays(-1, to: today)
        let asset = InvestmentAsset(name: "Apple", code: "AAPL", market: "NASDAQ", kind: .stock, currency: .usd)
        let key = InvestmentDiskCache.historyKey(asset)
        let provisional = InvestmentQuote(day: session, price: 100, isDailyClose: false)
        try await cache.saveHistory(scope: "close", asset: asset, start: session, end: session, today: today, quotes: [provisional])
        let snapshot = try await cache.marketReadSnapshot(scope: "close")
        precondition(snapshot.missingWindows(key: key, start: session, end: session, today: today,
            observations: [provisional], requiredClose: session) == [session...session],
            "A same-day pre-close cache hit cannot suppress the actual closing request")
        precondition(snapshot.missingWindows(key: key, start: session, end: session, today: today,
            observations: [], requiredClose: session) == [session...session],
            "An unpublished closing value must be retried after it becomes available")
        let final = InvestmentQuote(day: session, price: 101, isDailyClose: true)
        precondition(snapshot.missingWindows(key: key, start: session, end: session, today: today,
            observations: [final], requiredClose: session).isEmpty, "A confirmed close remains reusable")
        precondition(snapshot.missingWindows(key: key, start: session, end: session, today: today,
            observations: [provisional], requiredClose: today).isEmpty, "Never extend a bounded request")
    }

    static func refreshReadsMarketCacheOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = InvestmentDiskCache(directory: directory)
        let today = InvestmentBook.day(), start = InvestmentBook.addDays(-179, to: today)
        let quotes = (0..<180).map { InvestmentQuote(day: InvestmentBook.addDays($0, to: start), price: Decimal($0 + 1), source: "测试行情", isDailyClose: true) }
        let assets = (0..<16).map { InvestmentAsset(name: "标的\($0)", code: "T\($0)", market: "XNAS", kind: .stock, currency: .usd) }
        for asset in assets { try await writer.saveHistory(scope: "batch", asset: asset, start: start, end: today, today: today, quotes: quotes) }
        let keys = assets.map(InvestmentDiskCache.historyKey) + [InvestmentCurrency.usd, .hkd].map(InvestmentDiskCache.rateKey)
        for key in keys.suffix(2) { try await writer.saveMarketHistory(scope: "batch", key: key, start: start, end: today, today: today, quotes: quotes) }
        let counter = MarketReadCounter()
        let reader = InvestmentDiskCache(directory: directory, readFile: { try counter.read($0) })
        for key in keys {
            let saved = try await reader.marketQuotes(scope: "batch", key: key)
            let missing = try await reader.missingWindows(scope: "batch", key: key, start: start, end: today, today: today, observations: saved)
            precondition(saved == quotes && missing.isEmpty)
        }
        let repeatedReads = counter.value
        precondition(repeatedReads == 36)
        counter.reset()
        let snapshot = try await reader.marketReadSnapshot(scope: "batch")
        for key in keys {
            let saved = snapshot.marketQuotes(key: key)
            let missing = snapshot.missingWindows(key: key, start: start, end: today, today: today, observations: saved)
            precondition(saved == quotes && missing.isEmpty)
        }
        precondition(counter.value == 1, "A fully cached refresh must decode the cache once across all assets and currencies")
        precondition(snapshot.historyCount == 18 && snapshot.quoteCount == 18 * 180)
        let tomorrow = InvestmentBook.addDays(1, to: today), after = InvestmentBook.addDays(2, to: today)
        let remaining = snapshot.missingWindows(key: keys[0], start: tomorrow, end: after, today: today,
            observations: [], additionalCoverage: [tomorrow...tomorrow])
        precondition(remaining == [after...after], "Successful queries in the same refresh must cover later overlapping requests")
        let changed = InvestmentQuote(day: today, price: 888, source: "测试行情", isDailyClose: true)
        try await writer.saveHistory(scope: "batch", asset: assets[0], start: today, end: today, today: today, quotes: [changed])
        precondition(snapshot.marketQuotes(key: keys[0]).last?.price == 180, "A refresh owns a stable immutable view")
        let next = try await reader.marketReadSnapshot(scope: "batch")
        precondition(next.marketQuotes(key: keys[0]).last?.price == 888, "A new refresh must see other cache instances' writes")
        let other = try await reader.marketReadSnapshot(scope: "other")
        precondition(other.marketQuotes(key: keys[0]).isEmpty)
        print("Market cache refresh: 18 series, \(repeatedReads) repeated file decodes -> 1 indexed read; unchanged quotes and coverage")
    }

    static func provisionalFXRefreshesDespiteCoverage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = InvestmentDiskCache(directory: directory)
        let records = InvestmentServerRecords()
        let yesterday = records.day.date(from: "2026-11-24")!
        let today = InvestmentBook.addDays(1, to: yesterday)
        let key = InvestmentDiskCache.rateKey(.usd)
        let provisional = InvestmentQuote(day: yesterday, price: 7, source: "old", isDailyClose: false)
        try await cache.saveMarketHistory(scope: "fx", key: key, start: yesterday, end: yesterday,
            today: today, quotes: [provisional])
        var snapshot = try await cache.marketReadSnapshot(scope: "fx")
        precondition(snapshot.missingWindows(key: key, start: yesterday, end: yesterday, today: today,
            observations: [provisional]) == [yesterday...yesterday], "Coverage cannot hide unfinished FX")
        let final = InvestmentQuote(day: yesterday, price: Decimal(string: "7.1")!, source: "欧洲央行", isDailyClose: true)
        try await cache.saveMarketHistory(scope: "fx", key: key, start: yesterday, end: yesterday,
            today: today, quotes: [final])
        try await cache.saveMarketHistory(scope: "fx", key: key, start: yesterday, end: yesterday,
            today: today, quotes: [.init(day: yesterday, price: 8, source: "other", isDailyClose: true)])
        snapshot = try await cache.marketReadSnapshot(scope: "fx")
        precondition(snapshot.marketQuotes(key: key) == [final], "A later batch cannot rewrite finalized disk FX")
        precondition(snapshot.missingWindows(key: key, start: yesterday, end: yesterday, today: today,
            observations: [final]).isEmpty)
        var book = InvestmentBook(accounts: [.init(name: "USD", currency: .usd, type: .securities)])
        book.addExchangeRates([provisional], for: .usd)
        book = try await cache.restoringMarketQuotes(in: book, scope: "fx")
        precondition(book.fx[.usd] == [final], "Cached final FX must promote a provisional book rate")
    }

    static func dailyCryptoSpotReuse() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = InvestmentDiskCache(directory: directory)
        let today = InvestmentBook.day(), yesterday = InvestmentBook.addDays(-1, to: today)
        let tomorrow = InvestmentBook.addDays(1, to: today)
        let token = InvestmentAsset(name: "Bitcoin", code: "BTC", market: "BINANCE", kind: .crypto, currency: .usd)
        let quote = InvestmentQuote(day: today, price: 90000, source: "Binance 现货", isDailyClose: false)
        let absent = try await cache.cachedCryptoSpotQuote(scope: "crypto-a", asset: token, on: today)
        precondition(absent == nil)
        for invalid in [InvestmentQuote(day: yesterday, price: 1, source: "Binance 现货"),
                        .init(day: tomorrow, price: 1, source: "Binance 现货"),
                        .init(day: today, price: 0, source: "Binance 现货"),
                        .init(day: today, price: -1, source: "Binance 现货"),
                        .init(day: today, price: .nan, source: "Binance 现货"),
                        .init(day: today, price: 1, source: "手动录入")] {
            let value = try await cache.cachedCryptoSpotQuote(scope: "crypto-a", asset: token, on: today, observations: [invalid])
            precondition(value == nil, "Only valid automatic quotes from today can satisfy a quote-only cache check")
        }
        try await cache.saveCryptoSpotQuote(scope: "crypto-a", asset: token, quote: quote, on: today)
        let restarted = InvestmentDiskCache(directory: directory)
        let persisted = try await restarted.cachedCryptoSpotQuote(scope: "crypto-a", asset: token, on: today)
        let newerServer = InvestmentQuote(day: today, price: 91000, source: "Twelve Data")
        let localFirst = try await restarted.cachedCryptoSpotQuote(scope: "crypto-a", asset: token, on: today, observations: [newerServer])
        let expired = try await restarted.cachedCryptoSpotQuote(scope: "crypto-a", asset: token, on: tomorrow)
        let otherScope = try await restarted.cachedCryptoSpotQuote(scope: "crypto-b", asset: token, on: today)
        precondition(persisted == quote && localFirst == quote && expired == nil && otherScope == nil,
                     "Same-day fetches survive restarts, expire on the next Beijing day and remain account/server scoped")
        var duplicate = token; duplicate.id = UUID()
        let sameCoin = try await restarted.cachedCryptoSpotQuote(scope: "crypto-a", asset: duplicate, on: today)
        precondition(sameCoin == quote, "Identical catalog identities may reuse one spot fetch")
        var other = token; other.code = "ETH"
        let otherCoin = try await restarted.cachedCryptoSpotQuote(scope: "crypto-a", asset: other, on: today)
        other = token; other.market = "OTHER"
        let otherMarket = try await restarted.cachedCryptoSpotQuote(scope: "crypto-a", asset: other, on: today)
        other = token; other.kind = .stock
        let otherKind = try await restarted.cachedCryptoSpotQuote(scope: "crypto-a", asset: other, on: today)
        precondition(otherCoin == nil && otherMarket == nil && otherKind == nil)
        let missingClose = try await restarted.missingWindows(scope: "crypto-a", key: InvestmentDiskCache.historyKey(token),
            start: today, end: today, today: today, observations: [])
        precondition(missingClose == [today...today], "Spot reuse must not claim historical daily-close coverage")

        // Server quotes also satisfy reuse when the local disk cache is empty.
        var book = InvestmentBook(); book.assets[token.id] = token; book.addQuotes([quote], assetID: token.id)
        let records = InvestmentServerRecords()
        let tables = try records.encode(book, revision: 1)
        let server = try records.decode(.init(generation: 1, revision: 1, tables: tables))
        let serverQuote = try await restarted.cachedCryptoSpotQuote(scope: "server-only", asset: token, on: today,
            observations: server.quotes[token.id] ?? [])
        precondition(serverQuote?.day == today && serverQuote?.price == quote.price,
                     "Reading the server before a cache miss must prevent a duplicate vendor request")
        let unchanged = try records.encode(book, revision: 1)
        precondition(unchanged == tables, "Cache lookup must not rewrite ledger records")

        // The fetch day is distinct from the date carried by the provider's quote.
        let dated = InvestmentQuote(day: yesterday, price: 1, source: "Coinbase 公开市场")
        try await restarted.saveCryptoSpotQuote(scope: "dated", asset: token, quote: dated, on: today)
        let fetchedToday = try await restarted.cachedCryptoSpotQuote(scope: "dated", asset: token, on: today)
        let datedExpired = try await restarted.cachedCryptoSpotQuote(scope: "dated", asset: token, on: tomorrow)
        precondition(fetchedToday == dated && datedExpired == nil)
        try await restarted.saveHistory(scope: "history-only", asset: token, start: today, end: today, today: today, quotes: [quote])
        let downloaded = try await restarted.cachedCryptoSpotQuote(scope: "history-only", asset: token, on: today)
        precondition(downloaded == quote, "A downloaded current-day vendor quote can be reused before server synchronization")
        try await restarted.saveHistory(scope: "empty", asset: token, start: today, end: today, today: today, quotes: [])
        let empty = try await restarted.cachedCryptoSpotQuote(scope: "empty", asset: token, on: today)
        precondition(empty == nil, "Empty or failed requests must remain eligible for retry")
    }
}
