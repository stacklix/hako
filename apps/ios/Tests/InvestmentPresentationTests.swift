import Foundation

private final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func read(_ url: URL) throws -> Data {
        lock.lock(); count += 1; lock.unlock()
        return try Data(contentsOf: url)
    }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@main struct InvestmentPresentationTests {
    static func main() async throws {
        try insuranceGainBasisOnlyChangesOverviewGain()
        try allocationUsesCurrentValues()
        let today = InvestmentBook.day()
        let yesterday = InvestmentBook.addDays(-1, to: today)
        var book = InvestmentBook()
        for index in 0..<6 {
            var account = InvestmentAccount(name: "账户\(index)", currency: .cny, type: .securities)
            let asset = InvestmentAsset(name: "持仓\(index)", code: String(format: "%06d.SZ", index + 1),
                                        market: "XSHE", kind: .stock, currency: .cny)
            book.assets[asset.id] = asset
            account.events = (0..<200).map { _ in .init(day: yesterday, kind: .deposit, amount: 1) }
            account.events.append(.init(day: yesterday, kind: .opening, assetID: asset.id, quantity: 10, price: 1))
            book.accounts.append(account)
            book.addQuotes([.init(day: yesterday, price: 1, isDailyClose: true),
                            .init(day: today, price: 2, isDailyClose: true)], assetID: asset.id)
        }
        book.fx[.usd] = [.init(day: yesterday, price: 7, isDailyClose: true)]
        let start = Date()
        for _ in 0..<10 {
            for account in book.accounts {
                _ = try book.ledger(account)
                _ = book.value(account)
            }
            _ = book.portfolio(on: today)
            _ = book.portfolio(on: today, currency: .usd)
            _ = book.dailyGains(from: today, through: today)
        }
        let repeated = Date().timeIntervalSince(start)
        let preparedStart = Date()
        let prepared = InvestmentPresentation(book: book, day: today)
        let preparation = Date().timeIntervalSince(preparedStart)
        for account in book.accounts {
            let ledger = try book.ledger(account)
            precondition(prepared.accounts[account.id]?.ledger?.cash == ledger.cash)
            precondition(prepared.accounts[account.id]?.value?.value == book.value(account)?.value)
            precondition(prepared.accounts[account.id]?.holdings.map(\.id)
                         == book.sortedHoldingAssets(in: ledger, showsZeroPositions: true).map(\.id))
        }
        precondition(prepared.total?.value == book.portfolio(on: today)?.value)
        precondition(prepared.dollars == book.portfolio(on: today, currency: .usd)?.value)
        precondition(prepared.dailyGain == book.dailyGains(from: today, through: today)[today])

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = InvestmentDiskCache(directory: directory)
        let records = InvestmentServerRecords()
        let tables = try records.encode(book, revision: 1)
        let state = InvestmentServerState(generation: 1, revision: 1, tables: tables)
        try await cache.save(state, scope: "presentation")
        let first = book.assets.values.first!
        try await cache.saveHistory(scope: "presentation", asset: first, start: yesterday, end: today, today: today,
                                    quotes: [.init(day: today, price: 999, isDailyClose: true)])
        let counter = ReadCounter()
        let reader = InvestmentDiskCache(directory: directory, readFile: { try counter.read($0) })
        let restored = try await reader.restoredBook(scope: "presentation")!
        precondition(counter.value == 1, "Startup must read/decode the whole cache only once, regardless of holding count")
        precondition(restored.book.quote(first.id)?.price == 2, "Confirmed quotes must take precedence over supplemental disk history")
        precondition(restored.book.accounts.count == book.accounts.count && restored.state.generation == 1)
        let missing = try await reader.restoredBook(scope: "other-account")
        precondition(missing == nil, "A cache from another account must never be installed")
        let rates = InvestmentDataCategory.rates.rows(in: state)
        try await cache.remove(scope: "presentation", category: .rates, rows: rates)
        let incomplete = try await reader.restoredBook(scope: "presentation")
        precondition(incomplete == nil, "An intentionally incomplete cache must reach the server")

        var changed = book
        let account = changed.accounts[0]
        try changed.post(.init(day: today, kind: .deposit, amount: 5), accountID: account.id)
        let write = try InvestmentPreparedWrite(draft: changed, current: book, state: state,
                                                dirtyFrom: records.day.string(from: today), includeInputs: true, includeSnapshots: false)
        precondition(write.changes["investment_events"]?.count == book.accounts.flatMap(\.events).count + 1)
        precondition(write.changes.keys.allSatisfy { !InvestmentServerRecords.snapshotTables.contains($0) })
        let next = InvestmentPresentation(book: changed)
        precondition(next.accounts[account.id]?.ledger?.cash == prepared.accounts[account.id]!.ledger!.cash + 5,
                     "The prepared account must reflect the confirmed write before the editor is dismissed")
        print(String(format: "Presentation: 1,206 events, 10 repeated renders %.3fs; one background preparation %.3fs", repeated, preparation))
        print("Presentation/cache/write: valuation parity, holdings order, one cache read, scope isolation, invalidation and prepared save data passed")
    }

    static func insuranceGainBasisOnlyChangesOverviewGain() throws {
        let today = InvestmentBook.day()
        let yesterday = InvestmentBook.addDays(-1, to: today)
        let records = InvestmentServerRecords()
        func check(_ book: InvestmentBook, cashValueGain: Decimal?, premiumGain: Decimal?) throws {
            let stored = try records.encode(book, revision: 1)
            let value = book.portfolio(on: today)?.value
            let daily = book.dailyGains(from: today, through: today)[today]
            let view = InvestmentPresentation(book: book, day: today)
            precondition(view.historicalGain(insuranceBasis: .cashValue) == cashValueGain)
            precondition(view.historicalGain(insuranceBasis: .paidPremiums) == premiumGain)
            precondition(view.total?.gain == cashValueGain && view.total?.value == value && view.dailyGain == daily,
                         "Changing the overview gain basis must not change asset totals or daily gain")
            let after = try records.encode(book, revision: 1)
            precondition(after == stored,
                         "Display calculations must not alter events, valuations, rates or saved snapshots")
            for account in book.accounts {
                precondition(view.accounts[account.id]?.value?.gain == book.value(account, on: today)?.gain,
                             "Account summaries keep their original cash-value basis")
            }
        }
        for currency in [InvestmentCurrency.cny, .hkd] {
            let owner = InvestmentAccount(name: "保险", currency: currency, type: .insurance)
            var book = InvestmentBook(accounts: [owner])
            let rate: Decimal = currency == .cny ? 1 : Decimal(string: "0.9")!
            if currency == .hkd { book.fx[.hkd] = [.init(day: yesterday, price: rate, isDailyClose: true)] }
            let id = try book.register(.init(name: "保单", code: "POLICY", market: "", kind: .insurance, currency: currency))
            try book.post(.init(day: yesterday, kind: .opening, assetID: id, quantity: 1, price: 10_000), accountID: owner.id)
            try check(book, cashValueGain: -10_000 * rate, premiumGain: 0)
            book.addQuotes([.init(day: yesterday, price: 8_000)], assetID: id)
            try check(book, cashValueGain: -2_000 * rate, premiumGain: 0)
            try book.post(.init(day: today, kind: .deposit, amount: 5_000), accountID: owner.id)
            try book.post(.init(day: today, kind: .buy, assetID: id, quantity: 1, price: 5_000), accountID: owner.id)
            try check(book, cashValueGain: -7_000 * rate, premiumGain: 0)
            try book.post(.init(day: today, kind: .insuranceWithdrawal, assetID: id, amount: 2_000, settledAmount: 6_000), accountID: owner.id)
            try check(book, cashValueGain: -7_000 * rate, premiumGain: 2_000 * rate)
            try book.post(.init(day: today, kind: .sell, assetID: id, quantity: 1, price: 6_000), accountID: owner.id)
            try check(book, cashValueGain: -7_000 * rate, premiumGain: -7_000 * rate)
            if currency == .hkd {
                book.fx = [:]
                try check(book, cashValueGain: nil, premiumGain: nil)
            }
        }
        let owner = InvestmentAccount(name: "证券", currency: .cny, type: .securities)
        var book = InvestmentBook(accounts: [owner])
        let id = try book.register(.init(name: "股票", code: "000001.SZ", market: "XSHE", kind: .stock, currency: .cny))
        try book.post(.init(day: yesterday, kind: .opening, assetID: id, quantity: 10, price: 10), accountID: owner.id)
        book.addQuotes([.init(day: yesterday, price: 20, isDailyClose: true)], assetID: id)
        try check(book, cashValueGain: 100, premiumGain: 100)
        let insurer = InvestmentAccount(name: "保险", currency: .cny, type: .insurance)
        book.accounts.append(insurer)
        let policy = try book.register(.init(name: "保单", code: "POLICY", market: "", kind: .insurance, currency: .cny))
        try book.post(.init(day: yesterday, kind: .opening, assetID: policy, quantity: 1, price: 10_000), accountID: insurer.id)
        book.addQuotes([.init(day: yesterday, price: 8_000)], assetID: policy)
        try check(book, cashValueGain: -1_900, premiumGain: 100)
        book.quotes[id] = nil
        try check(book, cashValueGain: nil, premiumGain: nil)
        try check(InvestmentBook(), cashValueGain: 0, premiumGain: 0)
    }

    static func allocationUsesCurrentValues() throws {
        let today = InvestmentBook.day()
        let yesterday = InvestmentBook.addDays(-1, to: today)
        let owner = InvestmentAccount(name: "证券", currency: .cny, type: .securities)
        let foreign = InvestmentAccount(name: "美元", currency: .usd, type: .securities)
        var book = InvestmentBook(accounts: [owner, foreign])
        let id = try book.register(.init(name: "股票", code: "000001.SZ", market: "XSHE", kind: .stock, currency: .cny))
        try book.post(.init(day: yesterday, kind: .opening, assetID: id, quantity: 2, price: 10), accountID: owner.id)
        try book.post(.init(day: yesterday, kind: .deposit, amount: 20), accountID: owner.id)
        try book.post(.init(day: yesterday, kind: .deposit, amount: 10), accountID: foreign.id)
        book.addQuotes([.init(day: yesterday, price: 10, isDailyClose: true),
                        .init(day: today, price: 20, isDailyClose: false)], assetID: id)
        book.fx[.usd] = [.init(day: yesterday, price: 7, isDailyClose: true),
                         .init(day: today, price: 8, isDailyClose: false)]
        let current = InvestmentPresentation(book: book, day: today)
        precondition(current.day == today)
        precondition(current.allocation.first { $0.id == owner.id.uuidString }?.value == 60)
        precondition(current.allocation.first { $0.id == foreign.id.uuidString }?.value == 80,
                     "Overview allocation converts current balances using the current available rate")
        let holdings = current.accounts[owner.id]!.allocation
        precondition(holdings.first { $0.id == id.uuidString }?.value == 40 && holdings.first { $0.id == "cash" }?.value == 20)
        precondition(holdings.compactMap(\.value).reduce(0, +) == current.accounts[owner.id]?.value?.value)
        precondition(book.value(book.accounts[0], on: yesterday)?.value == 40,
                     "Historical trend values remain distinct from current allocation")
        book.addQuotes([.init(day: today, price: 30, isDailyClose: false)], assetID: id)
        let refreshed = InvestmentPresentation(book: book, day: today)
        precondition(refreshed.allocation.first { $0.id == owner.id.uuidString }?.value == 80,
                     "Allocation refreshes when latest valuations change without loading trend history")
        book.quotes[id] = nil
        book.fx[.usd] = nil
        let missing = InvestmentPresentation(book: book, day: today)
        precondition(missing.allocation.allSatisfy { $0.value == nil }, "Missing prices or FX must not become zero")
        precondition(missing.accounts[owner.id]?.allocation.first { $0.id == "cash" }?.value == 20)
    }
}
