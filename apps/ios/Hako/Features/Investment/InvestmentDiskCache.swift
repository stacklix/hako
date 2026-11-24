import Foundation

enum InvestmentDataCategory: String, CaseIterable, Identifiable, Codable {
    case rates, stocks, funds, derivatives, crypto, daily, accounts, ledger
    var id: Self { self }
    var title: String {
        switch self {
        case .rates: "历史汇率"
        case .stocks: "股票与 ETF 收盘价"
        case .funds: "基金历史净值"
        case .derivatives: "期货与期权行情"
        case .crypto: "加密资产日终价"
        case .daily: "投资资产日终快照"
        case .accounts: "投资账户日终快照"
        case .ledger: "账本记录"
        }
    }
    var section: String { [.daily, .accounts].contains(self) ? "快照" : self == .ledger ? "账本记录" : "行情与汇率" }
    func rows(in state: InvestmentServerState) -> [InvestmentCachedRow] {
        let instruments = Dictionary(state.tables["market_instruments", default: []].compactMap { row in
            row["id"].map { ($0, row) }
        }, uniquingKeysWith: { _, last in last })
        let accounts = Dictionary(state.tables["investment_accounts", default: []].compactMap { row in
            row["id"].map { ($0, row["name"] ?? $0) }
        }, uniquingKeysWith: { _, last in last })
        var result: [InvestmentCachedRow] = []
        for (table, rows) in state.tables {
            for row in rows {
                let instrument = instruments[row["instrument_id"] ?? ""] ?? [:]
                let kind = instrument["asset_type"] ?? ""
                let matches: Bool = switch self {
                case .rates: table == "market_daily_fx"
                case .stocks: table == "market_daily_prices" && ["stock", "etf"].contains(kind)
                case .funds: table == "market_daily_prices" && kind == "fund"
                case .derivatives: table == "market_daily_prices" && ["future", "option"].contains(kind)
                case .crypto: table == "market_daily_prices" && kind == "crypto"
                case .daily: table == "investment_daily_snapshots"
                case .accounts: table == "investment_account_daily_snapshots"
                case .ledger: !["market_daily_fx", "market_daily_prices", "investment_daily_snapshots", "investment_account_daily_snapshots"].contains(table)
                }
                guard matches else { continue }
                let group = switch self {
                case .rates: (row["base_currency"] ?? "") + " / " + (row["quote_currency"] ?? "")
                case .daily: "全部投资账户"
                case .accounts: accounts[row["account_id"] ?? ""] ?? "投资账户"
                case .ledger: table
                default: (instrument["name"] ?? "行情") + " · " + (instrument["symbol"] ?? "")
                }
                result.append(.init(table: table, fields: row, group: group))
            }
        }
        return result.sorted { $0.day == $1.day ? $0.id < $1.id : $0.day > $1.day }
    }
}

struct InvestmentCachedRow: Identifiable, Hashable {
    let table: String
    let fields: InvestmentServerRow
    let group: String
    let id: String
    let bytes: Int
    init(table: String, fields: InvestmentServerRow, group: String) {
        self.table = table; self.fields = fields; self.group = group
        id = table + fields.keys.sorted().map { "|\($0)=\(fields[$0]!)" }.joined()
        bytes = (try? JSONEncoder().encode(fields).count) ?? 0
    }
    var day: String { fields["valuation_date"] ?? fields["snapshot_date"] ?? fields["rate_date"] ?? fields["session_date"] ?? fields["effective_date"] ?? "" }
    var value: String {
        for field in ["rate", "price", "total_cny", "holdings_native", "amount", "name"] {
            if fields[field] != nil { return displayValue(for: field) }
        }
        return "—"
    }
    func displayValue(for field: String) -> String {
        guard let raw = fields[field] else { return "—" }
        guard ["amount", "quantity", "unit_price", "fee", "settled_amount", "annual_rate", "margin_delta",
               "price", "rate", "value", "contract_multiplier", "total_cny", "total_usd",
               "cumulative_gain_cny", "daily_gain_cny", "cash_native", "holdings_native", "gain_native"].contains(field),
              let value = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")) else { return raw }
        if field == "quantity" { return NSDecimalNumber(decimal: value).stringValue }
        return InvestmentPrecision.display(value, exchangeRate: field == "rate", unitPrice: field == "unit_price" || field == "price")
    }
}

// Ledger state is server-confirmed. Market histories also retain downloaded
// observations until server synchronization succeeds; no credentials or pending edits.
// The caller supplies a digest of server URL + account, never a raw path or username.
actor InvestmentDiskCache {
    static let shared = InvestmentDiskCache()
    private let directory: URL
    private let readFile: @Sendable (URL) throws -> Data
    private struct History: Codable {
        let key: String
        let start: Date
        let end: Date
        let checkedDay: Date
        let quotes: [InvestmentQuote]
    }
    private struct Entry: Codable {
        var state: InvestmentServerState?
        var incomplete = false
        var histories: [History] = []
    }
    init(directory: URL? = nil, readFile: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }) {
        self.readFile = readFile
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hako/InvestmentCache", isDirectory: true)
    }
    private func url(_ scope: String) throws -> URL {
        guard !scope.isEmpty, scope.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        return directory.appendingPathComponent(scope + ".json")
    }
    private func entry(_ scope: String) throws -> Entry {
        let file = try url(scope)
        guard FileManager.default.fileExists(atPath: file.path) else { return Entry() }
        return try JSONDecoder().decode(Entry.self, from: readFile(file))
    }
    private func persist(_ entry: Entry, scope: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = try url(scope)
        try JSONEncoder().encode(entry).write(to: file, options: .atomic)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var mutable = file; try mutable.setResourceValues(values)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
        #endif
    }
    func load(scope: String) throws -> InvestmentServerState? {
        let entry = try entry(scope)
        return entry.incomplete ? nil : entry.state
    }
    func restoredBook(scope: String) throws -> (state: InvestmentServerState, book: InvestmentBook)? {
        let cached = try entry(scope)
        guard !cached.incomplete, let state = cached.state else { return nil }
        return (state, restoreMarketQuotes(in: try InvestmentServerRecords().decode(state), cached: cached))
    }
    func restoringMarketQuotes(in book: InvestmentBook, scope: String) throws -> InvestmentBook {
        restoreMarketQuotes(in: book, cached: try entry(scope))
    }
    private func restoreMarketQuotes(in source: InvestmentBook, cached: Entry) -> InvestmentBook {
        let histories = Dictionary(grouping: cached.histories, by: \.key)
        var restored = source
        for asset in source.assets.values where !asset.kind.isManual {
            let saved = histories[Self.historyKey(asset), default: []].flatMap(\.quotes)
            let known = Set((source.quotes[asset.id] ?? []).filter { $0.price > 0 && $0.isDailyClose != false }.map(\.day))
            if !saved.isEmpty { restored.addQuotes(saved.filter { !known.contains($0.day) }, assetID: asset.id) }
        }
        for currency in InvestmentCurrency.allCases where currency != .cny {
            let saved = histories[Self.rateKey(currency), default: []].flatMap(\.quotes)
            let known = Set((source.fx[currency] ?? []).filter { $0.price > 0 && $0.isDailyClose != false }.map(\.day))
            if !saved.isEmpty { restored.addExchangeRates(saved.filter { !known.contains($0.day) }, for: currency) }
        }
        return restored
    }
    func snapshot(scope: String) throws -> InvestmentServerState? { try entry(scope).state }
    func byteCount(scope: String) throws -> Int64 {
        let file = try url(scope)
        guard FileManager.default.fileExists(atPath: file.path) else { return 0 }
        return (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
    }
    func save(_ state: InvestmentServerState, scope: String) throws {
        var entry = (try? entry(scope)) ?? Entry()
        entry.state = state; entry.incomplete = false
        try persist(entry, scope: scope)
    }
    func remove(scope: String, category: InvestmentDataCategory? = nil, rows: [InvestmentCachedRow]? = nil) throws {
        guard let category else {
            let file = try url(scope)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            return
        }
        var entry = try entry(scope)
        guard var state = entry.state else { return }
        let selected = rows ?? category.rows(in: state)
        for table in Set(selected.map(\.table)) {
            let deleted = Set(selected.filter { $0.table == table }.map(\.fields))
            state.tables[table] = state.tables[table, default: []].filter { !deleted.contains($0) }
        }
        entry.state = state; entry.incomplete = true
        // Range coverage can no longer prove the presence of a deleted observation.
        entry.histories = []
        try persist(entry, scope: scope)
    }
    static func historyKey(_ asset: InvestmentAsset) -> String {
        [asset.id.uuidString, asset.code, asset.market, asset.currency.rawValue, asset.kind.rawValue].joined(separator: "|")
    }
    static func rateKey(_ currency: InvestmentCurrency) -> String { "fx|" + currency.rawValue + "|CNY" }
    private func coverage(_ histories: [History], key: String, today: Date) -> [ClosedRange<Date>] {
        histories.filter { $0.key == key }.compactMap { range in
            // An unfinished query day must be checked again on the next day.
            let end = range.checkedDay < today && range.end >= range.checkedDay
                ? InvestmentBook.addDays(-1, to: range.checkedDay) : range.end
            return range.start <= end ? range.start...end : nil
        }
    }
    func marketQuotes(scope: String, key: String) throws -> [InvestmentQuote] {
        InvestmentBook.merge([], try entry(scope).histories.filter { $0.key == key }.flatMap(\.quotes))
    }
    func missingWindows(scope: String, key: String, start: Date, end: Date, today: Date,
                        observations: [InvestmentQuote]) throws -> [ClosedRange<Date>] {
        let entry = try entry(scope)
        return InvestmentHistoryRange.missingWindows(from: start, through: end, observations: observations,
            covered: entry.incomplete ? [] : coverage(entry.histories, key: key, today: today))
    }
    func history(scope: String, asset: InvestmentAsset, start: Date, end: Date, today: Date) throws -> [InvestmentQuote]? {
        let entry = try entry(scope)
        guard !entry.incomplete else { return nil }
        let key = Self.historyKey(asset)
        let quotes = InvestmentBook.merge([], entry.histories.filter { $0.key == key }.flatMap(\.quotes))
        guard InvestmentHistoryRange.missingWindows(from: start, through: end, observations: quotes,
            covered: coverage(entry.histories, key: key, today: today)).isEmpty else { return nil }
        return quotes.filter { $0.day >= start && $0.day <= end }
    }
    func saveHistory(scope: String, asset: InvestmentAsset, start: Date, end: Date, today: Date, quotes: [InvestmentQuote]) throws {
        try saveMarketHistory(scope: scope, key: Self.historyKey(asset), start: start, end: end, today: today, quotes: quotes)
    }
    func saveMarketHistory(scope: String, key: String, start: Date, end: Date, today: Date, quotes: [InvestmentQuote]) throws {
        var entry = try entry(scope)
        entry.histories.removeAll { $0.key == key && $0.start >= start && $0.end <= end }
        entry.histories.append(.init(key: key, start: start, end: end, checkedDay: today, quotes: quotes))
        try persist(entry, scope: scope)
    }
}
