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
    struct Account {
        var ledger: InvestmentLedger?
        var error: String?
        var value: InvestmentValuation?
        var dailyGain: Decimal?
        var holdings: [InvestmentAsset] = []
        var allocation: [InvestmentAllocationItem] = []
    }
    let day: Date
    var accounts: [UUID: Account] = [:]
    var total: InvestmentValuation?
    var dollars: Decimal?
    var dailyGain: Decimal?
    var allocation: [InvestmentAllocationItem] = []
    private var gainUsingInsurancePremiums: Decimal?

    func historicalGain(insuranceBasis: InvestmentInsuranceGainBasis) -> Decimal? {
        insuranceBasis == .paidPremiums ? gainUsingInsurancePremiums : total?.gain
    }

    init(book: InvestmentBook, day: Date = InvestmentBook.day()) {
        self.day = day
        for account in book.accounts {
            do {
                let ledger = try book.ledger(account, through: day)
                let previous = book.value(account, on: InvestmentBook.addDays(-1, to: day), requiresDailyPrices: true)
                let daily = book.value(ledger, on: day, requiresDailyPrices: true)
                let holdings = book.sortedHoldingAssets(in: ledger, showsZeroPositions: true, on: day)
                let allocation = holdings.map { asset in
                    InvestmentAllocationItem(id: asset.id.uuidString, name: asset.name,
                        value: ledger.positions[asset.id].flatMap { book.positionValue($0, asset: asset, on: day) })
                } + [InvestmentAllocationItem(id: "cash", name: "现金", value: ledger.cash)]
                accounts[account.id] = Account(ledger: ledger, value: book.value(ledger, on: day, requiresDailyPrices: false),
                    dailyGain: daily.flatMap { now in previous.map { now.gain - $0.gain } },
                    holdings: holdings, allocation: allocation)
            } catch {
                accounts[account.id] = Account(error: error.localizedDescription)
            }
        }
        total = book.portfolio(on: day)
        allocation = book.accounts.map { account in
            let current = accounts[account.id]?.value?.value
            return InvestmentAllocationItem(id: account.id.uuidString, name: account.name,
                value: current.flatMap {
                    book.convert($0, from: account.currency, to: .cny, on: day)
                })
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
}

struct InvestmentPreparedWrite {
    let changes: InvestmentServerTables
    let delta: [String: InvestmentRecordChange]
    let through: String?

    init(draft: InvestmentBook, current: InvestmentBook, state: InvestmentServerState,
         dirtyFrom: String?, includeInputs: Bool, includeSnapshots: Bool) throws {
        let records = InvestmentServerRecords()
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
            let deletes = (current[table] ?? []).filter { !available.contains(key($0)) }.map { row in
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
            state.tables[table] = InvestmentServerRecords.ordered(Array(rows.values))
        }
        state.generation = generation; state.revision = revision
        state.dirtyFrom = dirtyFrom; state.through = through
        return state
    }
}
