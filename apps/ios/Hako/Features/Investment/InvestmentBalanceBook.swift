import Foundation

enum InvestmentBalanceCategory: String, Codable, CaseIterable, Identifiable {
    case cash = "流动资金"
    case investments = "投资理财"
    case fixed = "固定资产"
    case receivables = "应收款"
    case liabilities = "负债"

    var id: Self { self }
    static let assets: [Self] = [.cash, .investments, .fixed, .receivables]
}

struct InvestmentBalanceRecord: Codable, Equatable, Identifiable {
    var id = UUID()
    let recordedAt: Date
    let amount: Decimal

    static func chronological(_ lhs: Self, _ rhs: Self) -> Bool {
        lhs.recordedAt == rhs.recordedAt ? lhs.id.uuidString < rhs.id.uuidString : lhs.recordedAt < rhs.recordedAt
    }
}

struct InvestmentBalanceAccount: Codable, Identifiable {
    var id = UUID()
    let name: String
    let category: InvestmentBalanceCategory
    fileprivate(set) var records: [InvestmentBalanceRecord]

    init(id: UUID = UUID(), name: String, category: InvestmentBalanceCategory, records: [InvestmentBalanceRecord]) {
        self.id = id
        self.name = name
        self.category = category
        self.records = records.sorted(by: InvestmentBalanceRecord.chronological)
    }

    func latest(on day: Date) -> InvestmentBalanceRecord? {
        records.last { InvestmentBook.day($0.recordedAt) <= day }
    }
}

struct InvestmentBalanceLedger: Codable {
    private(set) var accounts: [InvestmentBalanceAccount] = []
    fileprivate var investmentMonthEnds: [Date: Decimal]? = nil

    init(accounts: [InvestmentBalanceAccount] = [], investmentMonthEnds: [Date: Decimal]? = nil) {
        self.accounts = accounts
        self.investmentMonthEnds = investmentMonthEnds
    }

    var earliest: Date? { accounts.compactMap { $0.records.first?.recordedAt }.min().map(InvestmentBook.day) }
    var investmentSnapshots: [Date: Decimal] { investmentMonthEnds ?? [:] }

    mutating func replaceInvestmentSnapshots(_ snapshots: [Date: Decimal]) { investmentMonthEnds = snapshots }

    mutating func discardInvestmentSnapshots(from day: Date) {
        investmentMonthEnds = investmentMonthEnds?.filter { $0.key < day }
    }

    mutating func add(_ name: String, category: InvestmentBalanceCategory, amount: Decimal, at date: Date = .now) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 36 else {
            throw InvestmentError.invalid("请输入 1 至 36 个字符的账户名称。")
        }
        guard category != .investments else { throw InvestmentError.invalid("投资账户余额来自投资记账。") }
        try validate(amount)
        let record = InvestmentBalanceRecord(recordedAt: date, amount: amount)
        accounts.append(InvestmentBalanceAccount(name: name, category: category, records: [record]))
    }

    mutating func update(_ id: UUID, amount: Decimal, at date: Date = .now) throws {
        try validate(amount)
        guard let index = accounts.firstIndex(where: { $0.id == id }) else {
            throw InvestmentError.invalid("该账户已不存在。")
        }
        let last = accounts[index].records.last
        guard last?.amount != amount else { return }
        guard last.map({ date >= $0.recordedAt }) ?? true else {
            throw InvestmentError.invalid("当前时间早于该账户的最近一次更新。")
        }
        accounts[index].records.append(InvestmentBalanceRecord(recordedAt: date, amount: amount))
    }

    mutating func replaceRecord(_ original: InvestmentBalanceRecord, accountID: UUID, amount: Decimal,
                                on date: Date, now: Date = .now) throws {
        try validate(amount)
        let day = InvestmentBook.day(date)
        guard day <= InvestmentBook.day(now) else { throw InvestmentError.invalid("记账日期不能晚于今天。") }
        let (accountIndex, recordIndex) = try location(of: original, accountID: accountID)
        let originalDay = InvestmentBook.day(original.recordedAt)
        let stamp = day == originalDay ? original.recordedAt :
            min(now, day.addingTimeInterval(original.recordedAt.timeIntervalSince(originalDay)))
        accounts[accountIndex].records[recordIndex] = InvestmentBalanceRecord(id: original.id, recordedAt: stamp, amount: amount)
        accounts[accountIndex].records.sort(by: InvestmentBalanceRecord.chronological)
    }

    mutating func deleteRecord(_ original: InvestmentBalanceRecord, accountID: UUID) throws {
        let (accountIndex, recordIndex) = try location(of: original, accountID: accountID)
        accounts[accountIndex].records.remove(at: recordIndex)
    }

    private func location(of record: InvestmentBalanceRecord, accountID: UUID) throws -> (Int, Int) {
        guard let accountIndex = accounts.firstIndex(where: { $0.id == accountID }),
              let recordIndex = accounts[accountIndex].records.firstIndex(of: record) else {
            throw InvestmentError.invalid("这笔余额记录已变更，请重新打开后再操作。")
        }
        return (accountIndex, recordIndex)
    }

    private func validate(_ amount: Decimal) throws {
        var value = amount
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 2, .plain)
        guard !amount.isNaN, amount >= 0, amount <= 999_999_999.99, rounded == amount else {
            throw InvestmentError.invalid("请输入有效余额，最多保留两位小数。")
        }
    }
}

struct InvestmentBalanceSnapshot {
    let day: Date
    let manual: [InvestmentBalanceCategory: Decimal]
    let investment: Decimal?
    let updatedAt: Date?

    func amount(_ category: InvestmentBalanceCategory) -> Decimal? {
        switch category {
        case .investments: investment
        case .liabilities: manual[category, default: 0] + investmentDeficit
        default: manual[category, default: 0]
        }
    }

    var investmentDeficit: Decimal { max(0, -(investment ?? 0)) }

    func assetContribution(_ category: InvestmentBalanceCategory) -> Decimal? {
        amount(category).map { max(0, $0) }
    }

    var assets: Decimal? {
        investment.map { manual[.cash, default: 0] + manual[.fixed, default: 0] + manual[.receivables, default: 0] + max(0, $0) }
    }
    var liabilities: Decimal { manual[.liabilities, default: 0] + investmentDeficit }
    var net: Decimal? { assets.map { $0 - liabilities } }
    var debtRatio: Decimal? { assets.flatMap { $0 > 0 ? liabilities / $0 : nil } }
}

enum InvestmentBalanceHistoryFilter: Hashable {
    case all, account(UUID), investment
}

struct InvestmentBalanceChange: Identifiable {
    enum ID: Hashable {
        case manual(accountID: UUID, recordID: UUID)
        case investment(Date)
    }

    let id: ID
    let name: String
    let category: InvestmentBalanceCategory
    let recordedAt: Date
    let before: Decimal?
    let after: Decimal

    var day: Date { InvestmentBook.day(recordedAt) }

    var manualRecord: (accountID: UUID, record: InvestmentBalanceRecord)? {
        guard case let .manual(accountID, recordID) = id else { return nil }
        return (accountID, InvestmentBalanceRecord(id: recordID, recordedAt: recordedAt, amount: after))
    }
}

extension InvestmentBook {
    private var investmentSnapshots: [Date: Decimal] { balanceSheet?.investmentSnapshots ?? [:] }

    var balanceEarliest: Date? {
        [earliest, balanceSheet?.earliest, investmentSnapshots.keys.min()].compactMap { $0 }.min()
    }

    static func previousMonthEnd(before day: Date) -> Date {
        let start = calendar.dateInterval(of: .month, for: day)?.start ?? day
        return addDays(-1, to: start)
    }

    private static func monthEnds(from start: Date, through end: Date) -> [Date] {
        var ends: [Date] = []
        var date = start
        while date <= end, let month = calendar.dateInterval(of: .month, for: date) {
            let close = addDays(-1, to: month.end)
            if close <= end { ends.append(close) }
            date = month.end
        }
        return ends
    }

    @discardableResult
    mutating func recordCompletedInvestmentMonths(before today: Date = Self.day()) -> Bool {
        guard let earliest else { return false }
        var ledger = balanceSheet ?? InvestmentBalanceLedger()
        var snapshots = ledger.investmentSnapshots
        let priorCount = snapshots.count
        for close in Self.monthEnds(from: earliest, through: Self.previousMonthEnd(before: today)) where snapshots[close] == nil {
            if let valuation = portfolio(on: close) { snapshots[close] = valuation.value }
        }
        guard snapshots.count != priorCount else { return false }
        ledger.investmentMonthEnds = snapshots
        balanceSheet = ledger
        return true
    }

    func investmentBalance(_ account: InvestmentAccount, on day: Date) -> Decimal? {
        value(account, on: day).flatMap { convert($0.value, from: account.currency, to: .cny, on: day) }
    }

    func balanceSnapshot(on day: Date, today: Date = Self.day(), updatedAt: Date? = nil) -> InvestmentBalanceSnapshot {
        var amounts: [InvestmentBalanceCategory: Decimal] = [:]
        var lastUpdate = updatedAt
        for account in balanceSheet?.accounts ?? [] {
            guard let record = account.latest(on: day) else { continue }
            amounts[account.category, default: 0] += record.amount
            lastUpdate = max(lastUpdate ?? record.recordedAt, record.recordedAt)
        }
        let investment = day == today ? portfolio(on: day)?.value : historicalInvestment(on: day)
        return InvestmentBalanceSnapshot(day: day, manual: amounts, investment: investment, updatedAt: lastUpdate)
    }

    private func historicalInvestment(on day: Date) -> Decimal? {
        let monthEnd = Self.calendar.dateInterval(of: .month, for: day).map { Self.addDays(-1, to: $0.end) }
        let close = monthEnd == day ? day : Self.previousMonthEnd(before: day)
        if let amount = investmentSnapshots[close] { return amount }
        let first = [earliest, investmentSnapshots.keys.min()].compactMap { $0 }.min()
        return first.map { $0 <= day } == true ? nil : 0
    }

    func balanceUpdateDates(through day: Date, today: Date) -> [InvestmentBalanceCategory: Date] {
        var updates: [InvestmentBalanceCategory: Date] = [:]
        for account in balanceSheet?.accounts ?? [] {
            guard let record = account.latest(on: day) else { continue }
            updates[account.category] = max(updates[account.category] ?? record.recordedAt, record.recordedAt)
        }
        if day == today, let earliest, earliest <= today, portfolio(on: today) != nil {
            updates[.investments] = today
        } else {
            updates[.investments] = investmentSnapshots.keys.filter { $0 <= day }.max()
        }
        return updates
    }

    func balanceChanges(through day: Date, limit: Int, filter: InvestmentBalanceHistoryFilter = .all) -> [InvestmentBalanceChange] {
        guard limit > 0 else { return [] }
        var changesByDay: [Date: [InvestmentBalanceChange]] = [:]
        for account in balanceSheet?.accounts ?? [] where filter == .all || filter == .account(account.id) {
            var previous: Decimal?
            for record in account.records {
                let change = InvestmentBalanceChange(id: .manual(accountID: account.id, recordID: record.id), name: account.name, category: account.category,
                                                     recordedAt: record.recordedAt, before: previous, after: record.amount)
                guard change.day <= day else { break }
                changesByDay[change.day, default: []].append(change)
                previous = record.amount
            }
        }
        let snapshots = investmentSnapshots
        for (date, amount) in snapshots where (filter == .all || filter == .investment) && date <= day {
            let prior = snapshots[Self.previousMonthEnd(before: date)]
            let endOfDay = Self.addDays(1, to: date).addingTimeInterval(-1)
            changesByDay[date, default: []].append(
                InvestmentBalanceChange(id: .investment(date), name: InvestmentBalanceCategory.investments.rawValue,
                                        category: .investments, recordedAt: endOfDay, before: prior, after: amount)
            )
        }
        let newestFirst = changesByDay.keys.sorted(by: >).lazy.flatMap {
            (changesByDay[$0] ?? []).reversed().sorted { $0.recordedAt > $1.recordedAt }
        }
        return Array(newestFirst.prefix(limit))
    }

    func balanceDates(from start: Date, through end: Date) -> [Date] {
        guard start <= end else { return [] }
        var dates = Set(Self.monthEnds(from: start, through: end))
        dates.formUnion([start, end])
        let manualDates = (balanceSheet?.accounts ?? []).flatMap { $0.records.map { Self.day($0.recordedAt) } }
        dates.formUnion(manualDates.filter { $0 >= start && $0 <= end })
        return dates.sorted()
    }
}
