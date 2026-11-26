import Foundation

@main struct InvestmentSnapshotBatchTests {
    static let records = InvestmentServerRecords()
    static func day(_ value: String) -> Date { records.day.date(from: value)! }

    static func main() throws {
        try accountMonthsCommitBeforePortfolioAndResume()
        try obsoleteRowsAndEmptyLedgersCanBeRemoved()
        try monthBoundaryDailyGainKeepsUnroundedAnchor()
        try previewInputsCommitSeparatelyFromSnapshotBatches()
        precondition(InvestmentBook.snapshotMonthEnd(containing: day("2024-02-12")) == day("2024-02-29"))
        precondition(InvestmentBook.snapshotMonthEnd(containing: day("2026-12-31")) == day("2026-12-31"))
        print("Investment snapshot batches: account isolation, month checkpoints, retry, revision changes and obsolete rows passed")
    }

    static func apply(_ prepared: InvestmentPreparedWrite, dirty: String?, to state: inout InvestmentServerState) throws {
        let previous = try records.decode(state)
        let changed = !prepared.delta.isEmpty || dirty != state.dirtyFrom || prepared.through != state.through
        state = try InvestmentDeltaResponse(generation: state.generation + (changed ? 1 : 0), revision: state.revision,
            dirtyFrom: dirty, through: prepared.through, changes: prepared.delta).applying(to: state)
        let updated = try records.encode(records.updatingSnapshots(state, in: previous), revision: state.revision)
        let full = try records.encode(records.decode(state), revision: state.revision)
        for table in InvestmentServerRecords.names {
            precondition(InvestmentServerRecords.ordered(updated[table] ?? []) == InvestmentServerRecords.ordered(full[table] ?? []),
                         "Snapshot-only confirmation must match full decode and preserve source records: " + table)
        }
    }

    static func prepare(_ source: InvestmentBook, state: InvestmentServerState, batch: InvestmentSnapshotBatch,
                        dirty: String?) throws -> InvestmentPreparedWrite {
        try InvestmentPreparedWrite(draft: source, current: records.decode(state), state: state, dirtyFrom: dirty,
            includeInputs: false, includeSnapshots: true, snapshotBatch: batch)
    }

    static func accountMonthsCommitBeforePortfolioAndResume() throws {
        let first = day("2026-10-30"), end = day("2026-11-03")
        let a = InvestmentAccount(name: "A", currency: .cny, type: .securities)
        let b = InvestmentAccount(name: "B", currency: .cny, type: .securities)
        var archived = InvestmentAccount(name: "已归档", currency: .cny, type: .securities)
        archived.archivedAt = day("2026-11-01")
        var book = InvestmentBook(accounts: [a, b, archived])
        try book.post(.init(day: first, kind: .deposit, amount: 100), accountID: a.id)
        try book.post(.init(day: day("2026-11-02"), kind: .deposit, amount: 200), accountID: b.id)
        // Historical data of archived accounts still participates in total snapshots.
        book.accounts[2].events = [.init(day: day("2026-10-31"), kind: .deposit, amount: 30)]
        book.fx[.usd] = [.init(day: first, price: 7, isDailyClose: true)]
        book.dailySnapshots = book.makeDailySnapshots(through: end, rebuild: true)
        book.accounts[0].events[0].amount = 150
        book.accounts[1].events[0].amount = 250
        var state = InvestmentServerState(generation: 1, revision: 2, dirtyFrom: "2026-10-30", through: "2026-11-03",
            tables: try records.encode(book, revision: 1))
        let october = first...day("2026-10-31")
        var computed = try records.decode(state)
        computed.invalidateDailySnapshots(from: first)
        computed.dailySnapshots = computed.makeDailySnapshots(through: october.upperBound, rebuild: false)
        precondition(computed.snapshotBatchAccountIDs(in: october, state: state) == [a.id, archived.id])
        let accountA = InvestmentSnapshotBatch(window: october, accountID: a.id, completedThrough: day("2026-10-29"))
        let aWrite = try prepare(computed, state: state, batch: accountA, dirty: "2026-10-30")
        precondition(Set(aWrite.delta.keys) == ["investment_account_daily_snapshots"])
        precondition(aWrite.delta.values.flatMap(\.upserts).allSatisfy { $0["account_id"] == a.id.uuidString })
        try apply(aWrite, dirty: "2026-10-30", to: &state)
        // Simulate the next account failing: portfolio progress must not advance.
        precondition(state.dirtyFrom == "2026-10-30" && state.through == "2026-10-29")
        var resumed = try records.decode(state)
        precondition(resumed.dailySnapshots?.values.isEmpty == true,
                     "A previously later cutoff must not expose unfinished months")
        precondition(resumed.snapshotBatchStart(state: state, through: end, rebuild: true) == first)
        resumed.invalidateDailySnapshots(from: first)
        resumed.dailySnapshots = resumed.makeDailySnapshots(through: october.upperBound, rebuild: false)
        let retry = try prepare(resumed, state: state, batch: accountA, dirty: "2026-10-30")
        precondition(retry.delta.isEmpty, "An already confirmed account month must not be uploaded again")
        let archivedBatch = InvestmentSnapshotBatch(window: october, accountID: archived.id, completedThrough: day("2026-10-29"))
        try apply(prepare(resumed, state: state, batch: archivedBatch, dirty: "2026-10-30"), dirty: "2026-10-30", to: &state)
        let totalOctober = InvestmentSnapshotBatch(window: october, accountID: nil, completedThrough: october.upperBound)
        try apply(prepare(resumed, state: state, batch: totalOctober, dirty: "2026-11-01"), dirty: "2026-11-01", to: &state)
        let confirmed = try records.decode(state)
        precondition(confirmed.snapshotBatchStart(state: state, through: end, rebuild: true) == day("2026-11-01"))
        var changedInputs = state
        changedInputs.revision += 1
        precondition(confirmed.snapshotBatchStart(state: changedInputs, through: end, rebuild: true) == first,
                     "A prefix computed with older inputs must not be reused as a rebuild checkpoint")

        let november = day("2026-11-01")...end
        var next = confirmed
        next.invalidateDailySnapshots(from: next.snapshotCalculationStart(forMonthStarting: november.lowerBound))
        next.dailySnapshots = next.makeDailySnapshots(through: end, rebuild: false)
        for id in next.snapshotBatchAccountIDs(in: november, state: state) {
            let batch = InvestmentSnapshotBatch(window: november, accountID: id, completedThrough: october.upperBound)
            let write = try prepare(next, state: state, batch: batch, dirty: "2026-11-01")
            precondition(write.delta.values.flatMap(\.upserts).allSatisfy { ($0["snapshot_date"] ?? "") >= "2026-11-01" })
            if id == b.id {
                precondition(write.delta.values.flatMap(\.upserts).map { $0["snapshot_date"]! }.sorted() == ["2026-11-02", "2026-11-03"])
            }
            try apply(write, dirty: "2026-11-01", to: &state)
        }
        let totalNovember = InvestmentSnapshotBatch(window: november, accountID: nil, completedThrough: end)
        try apply(prepare(next, state: state, batch: totalNovember, dirty: nil), dirty: nil, to: &state)
        let finished = try records.decode(state)
        precondition(state.dirtyFrom == nil && state.through == "2026-11-03")
        precondition(finished.dailySnapshots?.values.count == 5)
        precondition(finished.dailySnapshots?.accountValues?[a.id]?.count == 5)
        precondition(finished.dailySnapshots?.accountValues?[b.id]?.count == 2)
        precondition(finished.dailySnapshots?.accountValues?[archived.id]?.count == 4)
        precondition(finished.inspectData(through: day("2026-11-04")).issues.isEmpty)
    }

    static func obsoleteRowsAndEmptyLedgersCanBeRemoved() throws {
        let account = InvestmentAccount(name: "Changed start", currency: .cny, type: .securities)
        var book = InvestmentBook(accounts: [account])
        try book.post(.init(day: day("2026-11-02"), kind: .deposit, amount: 10), accountID: account.id)
        book.fx[.usd] = [.init(day: day("2026-11-01"), price: 7, isDailyClose: true)]
        book.dailySnapshots = book.makeDailySnapshots(through: day("2026-11-03"), rebuild: true)
        var state = InvestmentServerState(generation: 1, revision: 1, through: "2026-11-03", tables: try records.encode(book, revision: 1))
        state.tables["investment_account_daily_snapshots", default: []].append([
            "account_id": account.id.uuidString, "snapshot_date": "2026-10-31", "cash_native": "0", "holdings_native": "0", "gain_native": "0", "status": "complete"])
        precondition(book.snapshotBatchStart(state: state, through: day("2026-11-03"), rebuild: true) == day("2026-10-31"))
        let batch = InvestmentSnapshotBatch(window: day("2026-10-31")...day("2026-10-31"), accountID: account.id, completedThrough: nil)
        let clean = try prepare(book, state: state, batch: batch, dirty: "2026-10-31")
        precondition(clean.delta[batch.table]?.deletes.count == 1)
        precondition(clean.delta[batch.table]?.upserts.isEmpty == true)
        try apply(clean, dirty: "2026-10-31", to: &state)
        let empty = InvestmentBook()
        precondition(empty.snapshotBatchStart(state: state, through: day("2026-11-03"), rebuild: true) == day("2026-11-02"))
        precondition(empty.snapshotBatchAccountIDs(in: day("2026-11-01")...day("2026-11-30"), state: state) == [account.id])
    }

    static func monthBoundaryDailyGainKeepsUnroundedAnchor() throws {
        let first = day("2026-03-30"), octoberEnd = day("2026-03-31"), novemberStart = day("2026-04-01")
        let account = InvestmentAccount(name: "Fractional gain", currency: .cny, type: .securities)
        var book = InvestmentBook(accounts: [account])
        let asset = try book.register(.init(name: "Stock", code: "600000.SH", market: "XSHG", kind: .stock, currency: .cny))
        try book.post(.init(day: first, kind: .opening, assetID: asset, quantity: 1, price: 1), accountID: account.id)
        book.addQuotes([.init(day: first, price: 1, isDailyClose: true),
                        .init(day: octoberEnd, price: Decimal(string: "2.0051")!, isDailyClose: true),
                        .init(day: novemberStart, price: Decimal(string: "2.0202")!, isDailyClose: true)], assetID: asset)
        book.fx[.usd] = [.init(day: first, price: 7, isDailyClose: true)]
        var continuous = book
        continuous.dailySnapshots = continuous.makeDailySnapshots(through: novemberStart, rebuild: true)
        let full = try records.encode(continuous, revision: 1)
        book.dailySnapshots = book.makeDailySnapshots(through: octoberEnd, rebuild: true)
        let state = InvestmentServerState(generation: 1, revision: 1, through: "2026-03-31", tables: try records.encode(book, revision: 1))
        var resumed = try records.decode(state)
        precondition(resumed.dailySnapshots?.values[octoberEnd]?.gain == Decimal(string: "1.01"))
        resumed.invalidateDailySnapshots(from: resumed.snapshotCalculationStart(forMonthStarting: novemberStart))
        resumed.dailySnapshots = resumed.makeDailySnapshots(through: novemberStart, rebuild: false)
        let batch = InvestmentSnapshotBatch(window: novemberStart...novemberStart, accountID: nil, completedThrough: novemberStart)
        let actual = try prepare(resumed, state: state, batch: batch, dirty: nil).delta[batch.table]!.upserts.first!
        let expected = full[batch.table]!.first { $0["snapshot_date"] == "2026-04-01" }!
        precondition(actual == expected && actual["daily_gain_cny"] == "0.02",
                     "A stored two-decimal previous-month gain must not change the next month's first daily gain")
    }

    static func previewInputsCommitSeparatelyFromSnapshotBatches() throws {
        let first = day("2026-03-30"), end = day("2026-04-01")
        let account = InvestmentAccount(name: "Approved snapshot preview", currency: .cny, type: .securities)
        var book = InvestmentBook(accounts: [account])
        let asset = try book.register(.init(name: "Stock", code: "600000.SH", market: "XSHG", kind: .stock, currency: .cny))
        try book.post(.init(day: first, kind: .opening, assetID: asset, quantity: 1, price: 1), accountID: account.id)
        book.fx[.usd] = [.init(day: first, price: 7, isDailyClose: true)]
        let state = InvestmentServerState(generation: 1, revision: 1, tables: try records.encode(book, revision: 1))
        let source = try records.decode(state)
        var preview = source
        preview.addQuotes([.init(day: first, price: 2, source: "Fetched for preview", isDailyClose: true)], assetID: asset)
        preview.dailySnapshots = preview.makeDailySnapshots(through: end, rebuild: true)
        // This was the old assistant confirmation path; it must remain forbidden.
        do {
            _ = try InvestmentPreparedWrite(draft: preview, current: source, state: state, dirtyFrom: nil,
                includeInputs: true, includeSnapshots: true)
            preconditionFailure("Source inputs and derived snapshots must never share a confirmation request")
        } catch is InvestmentError { }
        let input = try InvestmentPreparedWrite(draft: preview, current: source, state: state, dirtyFrom: "2026-03-30",
            includeInputs: true, includeSnapshots: false)
        precondition(!input.delta.isEmpty && input.delta.keys.allSatisfy { !InvestmentServerRecords.snapshotTables.contains($0) })
        let confirmed = try InvestmentDeltaResponse(generation: state.generation, revision: state.revision + 1,
            dirtyFrom: "2026-03-30", through: nil, changes: input.delta).applying(to: state)
        var monthly = try records.decode(confirmed)
        monthly.dailySnapshots = monthly.makeDailySnapshots(through: day("2026-03-31"), rebuild: true)
        let batch = InvestmentSnapshotBatch(window: first...day("2026-03-31"), accountID: account.id, completedThrough: nil)
        let output = try prepare(monthly, state: confirmed, batch: batch, dirty: "2026-03-30")
        precondition(Set(output.delta.keys) == ["investment_account_daily_snapshots"])
        precondition(output.delta.values.flatMap(\.upserts).allSatisfy { $0["snapshot_date"] != "2026-04-01" })
        precondition(confirmed.revision == 2 && output.through == nil,
                     "Monthly outputs use the newly confirmed input version and do not advance the total cutoff early")
    }
}
