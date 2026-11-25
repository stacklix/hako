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
        sharedMarketRemovalDoesNotDeletePublicRecords()
        try insuranceGainBasisOnlyChangesOverviewGain()
        try allocationUsesCurrentValues()
        try dailyAccountGainRanking()
        try accountAnalysisUsesCurrentValuations()
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
        precondition(write.delta["investment_events"]?.upserts.count == 1 && write.delta["investment_events"]?.deletes.isEmpty == true,
                     "Adding one trade must submit one row, not the table's other 1,200 events")
        let response = InvestmentDeltaResponse(generation: state.generation + 1, revision: state.revision + 1,
            dirtyFrom: records.day.string(from: today), through: state.through, changes: write.delta)
        let confirmed = try response.applying(to: state)
        precondition(confirmed.tables["investment_events"]?.count == state.tables["investment_events"]!.count + 1)
        precondition(confirmed.tables["investment_accounts"] == state.tables["investment_accounts"],
                     "A delta response must preserve all unaffected tables and records")
        let encodedResponse = try JSONSerialization.data(withJSONObject: ["generation": 2, "revision": 3,
            "dirtyFrom": NSNull(), "through": NSNull(), "changes": [:], "reloadRequired": true])
        let reloadResponse = try JSONDecoder().decode(InvestmentDeltaResponse.self, from: encodedResponse)
        precondition(reloadResponse.reloadRequired,
                     "Independent market updates must trigger a cache reload after the ledger is confirmed")
        let originalEvents = state.tables["investment_events"]!
        let removedID = originalEvents[0]["id"]!
        let deletion = InvestmentRecordChange.difference(changes: ["investment_events": originalEvents.filter { $0["id"] != removedID }], current: state.tables)
        precondition(deletion["investment_events"]?.upserts.isEmpty == true
                     && deletion["investment_events"]?.deletes == [["id": removedID]], "Deletes must send primary keys only")
        let price: InvestmentServerRow = ["instrument_id":"instrument", "session_date":"2026-11-25", "price_type":"close", "source":"external", "price":"100"]
        var serverPrice = price; serverPrice["revision"] = "12"
        precondition(InvestmentRecordChange.difference(changes: ["market_daily_prices":[price]], current: ["market_daily_prices":[serverPrice]]).isEmpty,
                     "Server-owned quote revisions must not cause unchanged quotes to be resent")
        let next = InvestmentPresentation(book: changed)
        precondition(next.accounts[account.id]?.ledger?.cash == prepared.accounts[account.id]!.ledger!.cash + 5,
                     "The prepared account must reflect the confirmed write before the editor is dismissed")
        print(String(format: "Presentation: 1,206 events, 10 repeated renders %.3fs; one background preparation %.3fs", repeated, preparation))
        print("Presentation/cache/write: valuation parity, holdings order, one cache read, scope isolation, invalidation and prepared save data passed")
    }

    static func dailyAccountGainRanking() throws {
        let today = InvestmentBook.day()
        let yesterday = InvestmentBook.addDays(-1, to: today)
        var book = InvestmentBook()
        func add(_ name: String, currency: InvestmentCurrency = .cny, gain: Decimal?, deposit: Decimal = 0) throws -> UUID {
            let type: InvestmentAccountType = currency == .cny ? .fundWealth : currency == .usd ? .crypto : .insurance
            let kind: InvestmentKind = currency == .cny ? .fund : currency == .usd ? .crypto : .insurance
            let code = currency == .cny ? String(format: "%06d.OF", book.accounts.count + 1) : "ASSET\(book.accounts.count)"
            let account = InvestmentAccount(name: name, currency: currency, type: type)
            book.accounts.append(account)
            let id = try book.register(.init(name: name, code: code, market: "", kind: kind, currency: currency))
            try book.post(.init(day: yesterday, kind: .opening, assetID: id, quantity: 1, price: 100), accountID: account.id)
            if deposit > 0 { try book.post(.init(day: today, kind: .deposit, amount: deposit), accountID: account.id) }
            if let gain {
                book.addQuotes([.init(day: yesterday, price: 100, isDailyClose: true),
                                .init(day: today, price: 100 + gain, isDailyClose: true)], assetID: id)
            }
            return account.id
        }
        let local = try add("本币盈利", gain: 10, deposit: 50)
        let foreign = try add("外币盈利", currency: .usd, gain: 3)
        let loss = try add("亏损", gain: -5)
        let tie = try add("同额盈利", gain: 10)
        let missing = try add("缺少报价", gain: nil)
        let missingFX = try add("缺少汇率", currency: .hkd, gain: 99)
        let empty = InvestmentAccount(name: "空账户", currency: .cny, type: .securities)
        book.accounts.append(empty)
        book.fx[.usd] = [.init(day: yesterday, price: 7, isDailyClose: true)]
        let prepared = InvestmentPresentation(book: book, day: today)
        let rows = prepared.dailyAccountGains
        precondition(rows.map(\.id) == [foreign, local, tie, empty.id, loss, missing, missingFX],
                     "Rank converted signed gains, keep ties and unavailable values in account order")
        let localRow = rows.first { $0.id == local }!
        precondition(localRow.gain == 10 && localRow.rate == Decimal(10) / 150,
                     "Today's deposit changes the return basis, never the gain")
        let foreignRow = rows.first { $0.id == foreign }!
        precondition(foreignRow.gain == 3 && foreignRow.gainCNY == 21 && foreignRow.rate == Decimal(3) / 100)
        precondition(rows.first { $0.id == loss }?.rate == Decimal(-5) / 100)
        precondition(rows.first { $0.id == empty.id }?.gain == 0 && rows.first { $0.id == empty.id }?.rate == nil)
        precondition(rows.first { $0.id == missing }?.gain == nil && rows.first { $0.id == missing }?.rate == nil)
        precondition(rows.first { $0.id == missingFX }?.gain == 99 && rows.first { $0.id == missingFX }?.gainCNY == nil)
        for row in rows { precondition(row.gain == prepared.accounts[row.id]?.dailyGain) }
    }

    static func accountAnalysisUsesCurrentValuations() throws {
        let today = InvestmentBook.day()
        let yesterday = InvestmentBook.addDays(-1, to: today)
        var book = InvestmentBook()
        func add(_ name: String, currency: InvestmentCurrency, price: Decimal) throws -> UUID {
            let account = InvestmentAccount(name: name, currency: currency, type: .securities)
            book.accounts.append(account)
            let code = currency == .usd ? "TEST" : "000001.SZ"
            let asset = try book.register(.init(name: name, code: code, market: currency == .usd ? "XNAS" : "XSHE",
                                                kind: .stock, currency: currency))
            try book.post(.init(day: yesterday, kind: .opening, assetID: asset, quantity: 10, price: 10), accountID: account.id)
            book.addQuotes([.init(day: today, price: price, isDailyClose: false)], assetID: asset)
            return account.id
        }
        let profit = try add("美元盈利", currency: .usd, price: 12)
        let loss = try add("人民币亏损", currency: .cny, price: 8)
        let empty = InvestmentAccount(name: "空账户", currency: .cny, type: .securities)
        book.accounts.append(empty)
        book.accounts[1].archivedAt = today
        book.fx[.usd] = [.init(day: today, price: 7, isDailyClose: false)]
        let original = try InvestmentServerRecords().encode(book, revision: 1)
        let view = InvestmentPresentation(book: book, day: today)
        let rows = view.accountAnalysis
        precondition(rows.map(\.id) == [profit, loss, empty.id], "Keep account order and color identity")
        precondition(rows.map(\.colorIndex) == [0, 1, 2] && rows[1].isArchived)
        precondition(rows[0].valueCNY == 840 && rows[0].gainCNY == 140 && rows[0].gainRate == Decimal(20) / 100)
        precondition(rows[1].valueCNY == 80 && rows[1].gainCNY == -20 && rows[1].gainRate == Decimal(-20) / 100)
        precondition(rows[0].gainWeight(losses: false) == 140 && rows[0].gainWeight(losses: true) == 0)
        precondition(rows[1].gainWeight(losses: false) == 0 && rows[1].gainWeight(losses: true) == 20)
        precondition(rows[2].valueCNY == 0 && rows[2].gainCNY == 0 && rows[2].gainRate == nil)
        precondition(rows[2].gainWeight(losses: true) == 0 && rows[2].gainWeight(losses: false) == 0)
        for row in rows {
            precondition(row.valueCNY == view.allocation.first { $0.id == row.id.uuidString }?.value)
        }
        let after = try InvestmentServerRecords().encode(book, revision: 1)
        precondition(after == original, "Analysis must not alter saved data")
        book.fx = [:]
        let missing = InvestmentPresentation(book: book, day: today).accountAnalysis[0]
        precondition(missing.valueCNY == nil && missing.gainCNY == nil && missing.gainWeight(losses: false) == nil,
                     "Missing FX must remain unknown, never become zero or part of a pie")
        precondition(missing.gainRate == Decimal(20) / 100, "Native return rate does not depend on conversion availability")
    }

    static func sharedMarketRemovalDoesNotDeletePublicRecords() {
        let quote: InvestmentServerRow = ["instrument_id": "ETF:US:QQQM:USD", "session_date": "2026-11-20", "price_type": "close", "source": "one", "price": "100"]
        let delta = InvestmentRecordChange.difference(changes: ["market_daily_prices": [], "investment_assets": []],
            current: ["market_daily_prices": [quote], "investment_assets": [["id": "position"]]])
        precondition(delta["market_daily_prices"] == nil && delta["investment_assets"]?.deletes == [["id": "position"]],
            "Removing a private position must keep the public history available to other ledgers")
        var updated = quote; updated["source"] = "two"; updated["price"] = "101"
        let changed = InvestmentRecordChange.difference(changes: ["market_daily_prices": [updated]], current: ["market_daily_prices": [quote]])
        precondition(changed["market_daily_prices"]?.upserts == [updated] && changed["market_daily_prices"]?.deletes.isEmpty == true,
            "Changing provider is an update to the same observation")
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
