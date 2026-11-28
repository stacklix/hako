import Foundation

enum InvestmentInsuranceGainBasis: String, CaseIterable, Identifiable {
    case cashValue = "按现金价值"
    case paidPremiums = "按已交保费"

    var id: Self { self }
}

struct InvestmentAllocationItem: Identifiable {
    let id: String
    let name: String
    let value: Decimal?
}

// Prepared once per book change, away from the main actor. View interactions
// such as opening a sheet must not replay the ledger or sort holdings again.
struct InvestmentPresentation {
    struct AccountAnalysis: Identifiable {
        let id: UUID
        let name: String
        let isArchived: Bool
        let colorIndex: Int
        let valueCNY: Decimal?
        let gainCNY: Decimal?
        let gainRate: Decimal?

        func gainWeight(losses: Bool) -> Decimal? {
            gainCNY.map { losses ? max(0, -$0) : max(0, $0) }
        }
    }
    struct DailyAccountGain: Identifiable {
        let id: UUID
        let name: String
        let currency: InvestmentCurrency
        let isArchived: Bool
        let gain: Decimal?
        let rate: Decimal?
        let gainCNY: Decimal?
    }
    struct Account {
        var ledger: InvestmentLedger?
        var error: String?
        var value: InvestmentValuation?
        var dailyGain: Decimal?
        var holdings: [InvestmentAsset] = []
        var allocation: [InvestmentAllocationItem] = []
        var transactions: [TransactionDay] = []
    }
    struct Transaction: Identifiable {
        var id: UUID { event.id }
        let event: InvestmentEvent
        let title: String
        let cashChange: Decimal?
    }
    struct TransactionDay: Identifiable {
        var id: Date { day }
        let day: Date
        var records: [Transaction]
    }
    let day: Date
    var accounts: [UUID: Account] = [:]
    var total: InvestmentValuation?
    var dollars: Decimal?
    var dailyGain: Decimal?
    var allocation: [InvestmentAllocationItem] = []
    var dailyAccountGains: [DailyAccountGain] = []
    var accountAnalysis: [AccountAnalysis] = []
    private var gainUsingInsurancePremiums: Decimal?

    func historicalGain(insuranceBasis: InvestmentInsuranceGainBasis) -> Decimal? {
        insuranceBasis == .paidPremiums ? gainUsingInsurancePremiums : total?.gain
    }

    init(book: InvestmentBook, day: Date = InvestmentBook.day()) {
        self.day = day
        var dailyValues: [UUID: InvestmentValuation] = [:]
        for account in book.accounts {
            do {
                let ledger = try book.ledger(account, through: day, includeRows: true)
                let previous = book.value(account, on: InvestmentBook.addDays(-1, to: day), requiresDailyPrices: true)
                let daily = book.value(ledger, on: day, requiresDailyPrices: true)
                dailyValues[account.id] = daily
                let holdings = book.sortedHoldingAssets(in: ledger, showsZeroPositions: true, on: day)
                let allocation = holdings.map { asset in
                    InvestmentAllocationItem(id: asset.id.uuidString, name: asset.name,
                        value: ledger.positions[asset.id].flatMap { book.positionValue($0, asset: asset, on: day) })
                } + [InvestmentAllocationItem(id: "cash", name: "现金", value: ledger.cash)]
                accounts[account.id] = Account(ledger: ledger, value: book.value(ledger, on: day, requiresDailyPrices: false),
                    dailyGain: daily.flatMap { now in previous.map { now.gain - $0.gain } },
                    holdings: holdings, allocation: allocation,
                    transactions: Self.transactionDays(account, book: book, cashRows: ledger.cashRows))
            } catch {
                accounts[account.id] = Account(error: error.localizedDescription,
                    transactions: Self.transactionDays(account, book: book, cashRows: []))
            }
        }
        dailyAccountGains = book.accounts.enumerated().map { index, account in
            let gain = accounts[account.id]?.dailyGain
            let basis = dailyValues[account.id].flatMap { value in gain.map { value.value - $0 } }
            let rate = basis.flatMap { basis in basis > 0 ? gain.map { $0 / basis } : nil }
            return (index, DailyAccountGain(id: account.id, name: account.name, currency: account.currency,
                isArchived: account.isArchived, gain: gain, rate: rate,
                gainCNY: gain.flatMap { book.convert($0, from: account.currency, to: .cny, on: day) }))
        }.sorted { left, right in
            switch (left.1.gainCNY, right.1.gainCNY) {
            case let (a?, b?) where a != b: return a > b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return left.0 < right.0
            }
        }.map(\.1)
        total = book.portfolio(on: day)
        allocation = book.accounts.map { account in
            let current = accounts[account.id]?.value?.value
            return InvestmentAllocationItem(id: account.id.uuidString, name: account.name,
                value: current.flatMap {
                    book.convert($0, from: account.currency, to: .cny, on: day)
                })
        }
        accountAnalysis = book.accounts.enumerated().map { index, account in
            let current = accounts[account.id]?.value
            return AccountAnalysis(id: account.id, name: account.name, isArchived: account.isArchived,
                colorIndex: index,
                valueCNY: current.flatMap { book.convert($0.value, from: account.currency, to: .cny, on: day) },
                gainCNY: current.flatMap { book.convert($0.gain, from: account.currency, to: .cny, on: day) },
                gainRate: current?.gainRate)
        }
        dollars = book.portfolio(on: day, currency: .usd)?.value
        dailyGain = book.dailyGains(from: day, through: day)[day]
        gainUsingInsurancePremiums = total?.gain
        for account in book.accounts {
            guard let gain = gainUsingInsurancePremiums, let ledger = accounts[account.id]?.ledger else {
                gainUsingInsurancePremiums = nil
                break
            }
            var adjustment: Decimal = 0
            for (id, position) in ledger.positions where position.quantity > 0 {
                guard let asset = book.asset(id), asset.kind == .insurance else { continue }
                guard let cashValue = book.positionValue(position, asset: asset, on: day) else {
                    gainUsingInsurancePremiums = nil
                    break
                }
                // Active insurance net cost contains its paid premiums; withdrawals
                // remain realized cash income. Closed policies keep their actual gain.
                adjustment += position.netCost - cashValue
            }
            guard gainUsingInsurancePremiums != nil else { break }
            if adjustment != 0 {
                guard let rate = book.rateToCNY(account.currency, on: day) else {
                    gainUsingInsurancePremiums = nil
                    break
                }
                gainUsingInsurancePremiums = gain + adjustment * rate
            }
        }
    }

    private static func transactionDays(_ account: InvestmentAccount, book: InvestmentBook,
                                        cashRows: [InvestmentCashRow]) -> [TransactionDay] {
        let cash = Dictionary(cashRows.map { ($0.id, $0.change) }, uniquingKeysWith: { _, latest in latest })
        var groups: [TransactionDay] = []
        // Use the ledger's stable sequence in reverse, without limiting the list
        // to current holdings, chart dates or events that move cash.
        for event in book.orderedEvents(account, through: .distantFuture).reversed() {
            let record = Transaction(event: event, title: book.eventTitle(event, accountID: account.id),
                                     cashChange: cash[event.id])
            if groups.last?.day == event.day {
                groups[groups.count - 1].records.append(record)
            } else {
                groups.append(TransactionDay(day: event.day, records: [record]))
            }
        }
        return groups
    }
}

struct InvestmentPreparedWrite {
    let changes: InvestmentServerTables
    let delta: [String: InvestmentRecordChange]
    let through: String?

    init(draft: InvestmentBook, current: InvestmentBook, state: InvestmentServerState,
         dirtyFrom: String?, includeInputs: Bool, includeSnapshots: Bool,
         snapshotBatch: InvestmentSnapshotBatch? = nil) throws {
        let records = InvestmentServerRecords()
        if let batch = snapshotBatch {
            guard includeSnapshots, !includeInputs else { throw InvestmentError.invalid("快照分批提交不能包含原始流水。") }
            let selected = records.encodeSnapshotBatch(draft, revision: state.revision, batch: batch)
            through = batch.completedThrough.map(records.day.string(from:))
            try InvestmentWriteValidation.validate(generation: state.generation, revision: state.revision,
                dirtyFrom: dirtyFrom, through: through, changes: [batch.table: selected], current: state.tables)
            let replacement = InvestmentServerRecords.ordered((state.tables[batch.table] ?? []).filter { !batch.includes($0) } + selected)
            delta = InvestmentRecordChange.difference(changes: [batch.table: replacement], current: state.tables)
            changes = delta.isEmpty ? [:] : [batch.table: replacement]
            return
        }
        if includeInputs { try records.validateEventInputs(draft, comparedTo: current) }
        let old = try records.encode(records.decode(state), revision: state.revision)
        let next = try records.encode(draft, revision: state.revision)
        var changes: InvestmentServerTables = [:]
        for name in InvestmentServerRecords.names {
            let output = InvestmentServerRecords.snapshotTables.contains(name)
            guard output ? includeSnapshots : includeInputs else { continue }
            let replacement = next[name] ?? []
            let previous = output ? InvestmentServerRecords.ordered(state.tables[name] ?? []) : old[name] ?? []
            if replacement != previous || (output && dirtyFrom != state.dirtyFrom) { changes[name] = replacement }
        }
        through = includeSnapshots ? draft.dailySnapshots.map { records.day.string(from: $0.through) } : state.through
        try InvestmentWriteValidation.validate(generation: state.generation, revision: state.revision,
            dirtyFrom: dirtyFrom, through: through, changes: changes, current: state.tables)
        if includeInputs { try records.validateLedgers(next, comparedTo: old) }
        self.changes = changes
        delta = InvestmentRecordChange.difference(changes: changes, current: old)
    }
}

struct InvestmentRecordChange: Codable {
    var upserts: [InvestmentServerRow]
    var deletes: [InvestmentServerRow]

    static func difference(changes: InvestmentServerTables, current: InvestmentServerTables) -> [String: Self] {
        var result: [String: Self] = [:]
        for (table, next) in changes {
            guard let rule = InvestmentWriteValidation.schema[table] else { continue }
            let columns = rule.keys.split(separator: " ").map(String.init)
            func key(_ row: InvestmentServerRow) -> String { columns.map { row[$0] ?? "" }.joined(separator: "\0") }
            let previous = Dictionary((current[table] ?? []).map { (key($0), $0) }, uniquingKeysWith: { _, last in last })
            let available = Set(next.map(key))
            let upserts = next.filter { row in
                guard let old = previous[key(row)] else { return true }
                // Quote revisions are assigned by the server, not encoded from the book.
                return old.filter { $0.key != "revision" } != row.filter { $0.key != "revision" }
            }
            let deletes = (InvestmentServerRecords.sharedTables.contains(table) ? [] : (current[table] ?? [])).filter { !available.contains(key($0)) }.map { row in
                Dictionary(uniqueKeysWithValues: columns.compactMap { column in row[column].map { (column, $0) } })
            }
            if !upserts.isEmpty || !deletes.isEmpty { result[table] = Self(upserts: upserts, deletes: deletes) }
        }
        return result
    }
}

struct InvestmentDeltaResponse: Decodable {
    let generation: Int64
    let revision: Int64
    let dirtyFrom: String?
    let through: String?
    let changes: [String: InvestmentRecordChange]
    var reloadRequired = false

    func applying(to original: InvestmentServerState) throws -> InvestmentServerState {
        var state = original
        for (table, change) in changes {
            guard let rule = InvestmentWriteValidation.schema[table] else { throw InvestmentError.invalid("服务端返回未知账本表。") }
            let keys = rule.keys.split(separator: " ").map(String.init)
            func key(_ row: InvestmentServerRow) -> String { keys.map { row[$0] ?? "" }.joined(separator: "\0") }
            var rows = Dictionary((state.tables[table] ?? []).map { (key($0), $0) }, uniquingKeysWith: { _, last in last })
            for row in change.deletes { rows[key(row)] = nil }
            for row in change.upserts { rows[key(row)] = row }
            if InvestmentServerRecords.snapshotTables.contains(table) {
                state.tables[table] = rows.keys.sorted().compactMap { rows[$0] }
            } else {
                state.tables[table] = InvestmentServerRecords.ordered(Array(rows.values))
            }
        }
        state.generation = generation; state.revision = revision
        state.dirtyFrom = dirtyFrom; state.through = through
        return state
    }
}

extension InvestmentBook {
    func snapshotCalculationStart(forMonthStarting day: Date) -> Date {
        // Recompute the preceding day's unrounded cumulative gain so the first
        // daily P&L in a month matches a single continuous calculation.
        max(earliest ?? day, Self.addDays(-1, to: day))
    }

    static func snapshotMonthEnd(containing day: Date) -> Date {
        let next = calendar.date(byAdding: .month, value: 1, to: calendar.dateInterval(of: .month, for: day)!.start)!
        return addDays(-1, to: next)
    }

    func snapshotBatchStart(state: InvestmentServerState, through end: Date, rebuild: Bool) -> Date? {
        let formatter = Self.snapshotDateFormatter()
        let existing = InvestmentServerRecords.snapshotTables.flatMap { state.tables[$0] ?? [] }
        let oldDates = existing.compactMap { $0["snapshot_date"].flatMap(formatter.date(from:)) }
        guard let earliest else { return oldDates.min() }
        let dirty = state.dirtyFrom.flatMap(formatter.date(from:))
        var start: Date?
        if rebuild {
            // A total row is the checkpoint after every account in that month was
            // committed. Reuse a prefix only when it belongs to these exact inputs.
            let rows = Dictionary((state.tables["investment_daily_snapshots"] ?? []).compactMap { row in
                row["snapshot_date"].map { ($0, row) }
            }, uniquingKeysWith: { _, last in last })
            var checked = earliest
            if let dirty {
                while checked < dirty, checked <= end,
                      rows[formatter.string(from: checked)]?["computed_revision"] == String(state.revision) {
                    checked = Self.addDays(1, to: checked)
                }
                start = checked >= dirty ? dirty : earliest
            } else { start = earliest }
        } else { start = dirty ?? snapshotStart(rebuild: false) }
        // Explicit rebuilds also remove obsolete derived rows before a ledger or
        // account's new start date; no source records are touched.
        if rebuild {
            for row in existing {
                guard let day = row["snapshot_date"].flatMap(formatter.date(from:)) else { continue }
                let first = row["account_id"].flatMap(UUID.init(uuidString:)).flatMap { account($0)?.earliest }
                let obsolete = row["account_id"] == nil ? day < earliest : first.map { day < $0 } ?? true
                if obsolete { start = min(start ?? day, day) }
            }
        }
        return start
    }

    func snapshotBatchAccountIDs(in window: ClosedRange<Date>, state: InvestmentServerState) -> [UUID] {
        var ids = accounts.filter { $0.earliest.map { $0 <= window.upperBound } ?? false }.map(\.id)
        let formatter = Self.snapshotDateFormatter()
        let old = (state.tables["investment_account_daily_snapshots"] ?? []).compactMap { row -> UUID? in
            guard let day = row["snapshot_date"].flatMap(formatter.date(from:)), window.contains(day) else { return nil }
            return row["account_id"].flatMap(UUID.init(uuidString:))
        }
        for id in Set(old).sorted(by: { $0.uuidString < $1.uuidString }) where !ids.contains(id) { ids.append(id) }
        return ids
    }
}
