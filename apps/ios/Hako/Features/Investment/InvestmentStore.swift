import Combine
import Foundation

@MainActor
final class InvestmentStore: ObservableObject {
    static let shared = InvestmentStore()

    @Published private(set) var book = InvestmentBook()
    @Published private(set) var loadError: String?
    @Published private(set) var configuredSources: Set<InvestmentQuoteSource> = []
    @Published private(set) var refreshing = false
    @Published private(set) var quoteStatus = ""

    private let file = URL.applicationSupportDirectory.appending(path: "Investment/ledger.json")
    private let secrets = SecureStorage.namespace("me.stackli.hako.investment")
    private var loaded = false
    private var ledgerRevision = UUID()
    private var lastAutomaticRefresh: Date?
    private var lastAutomaticCurrencies: Set<InvestmentCurrency> = []
    private var lastPublicQuoteRefresh: Date?
    private var lastAutomaticPublicQuotes: Set<UUID> = []
    private var cryptoCatalog: (loadedAt: Date, entries: [InvestmentAsset])?
    private var cryptoCatalogRequest: Task<[InvestmentAsset], Error>?
    private var contractCatalogs: [InvestmentContractBasis: [InvestmentContractExchange: (loadedAt: Date, entries: [InvestmentContractListing])]] = [:]
    var configured: Bool { !configuredSources.isEmpty }
    var canRefresh: Bool { configured || !rateCurrencies.isEmpty || !publicQuoteIDs.isEmpty }
    var rateCurrencies: Set<InvestmentCurrency> {
        guard !book.accounts.isEmpty else { return [] }
        var currencies = Set(book.accounts.map(\.currency)).subtracting([.cny]).union([.usd])
        if book.accounts.contains(where: { account in
            account.events.contains { book.asset($0.assetID)?.isStockConnect == true }
        }) {
            currencies.insert(.hkd)
        }
        return currencies
    }

    func load() {
        guard !loaded else { return }
        do {
            do {
                book = try JSONDecoder().decode(InvestmentBook.self, from: Data(contentsOf: file))
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                book = InvestmentBook()
            }
            loaded = true
            loadError = nil
            configuredSources = Set(keys().keys)
        } catch {
            loadError = "无法读取本地投资账本。"
        }
    }

    func update(_ change: (inout InvestmentBook) throws -> Void) throws {
        guard loaded else { throw InvestmentError.invalid(loadError ?? "投资账本尚未载入。") }
        var draft = book
        try change(&draft)
        try persist(draft)
        book = draft
    }

    func resetLedger() throws {
        let empty = InvestmentBook()
        try persist(empty)
        ledgerRevision = UUID()
        loaded = true
        book = empty
        loadError = nil
        configuredSources = Set(keys().keys)
        quoteStatus = ""
        lastAutomaticRefresh = nil
        lastAutomaticCurrencies = []
        lastPublicQuoteRefresh = nil
        lastAutomaticPublicQuotes = []
    }

    private func persist(_ ledger: InvestmentBook) throws {
        let data = try JSONEncoder().encode(ledger)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func saveKey(_ value: String, for source: InvestmentQuoteSource) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            try secrets.delete(account: source.rawValue)
            configuredSources.remove(source)
        } else {
            guard key.utf8.allSatisfy({ (33...126).contains($0) }) else {
                throw InvestmentError.invalid("行情凭据只能包含可见 ASCII 字符。")
            }
            try secrets.save(Data(key.utf8), account: source.rawValue, accessibility: .afterFirstUnlock)
            configuredSources.insert(source)
        }
        lastAutomaticRefresh = nil
        quoteStatus = ""
    }

    func loadKey(for source: InvestmentQuoteSource) throws -> String {
        guard let data = try secrets.read(account: source.rawValue) else { return "" }
        guard let value = String(data: data, encoding: .utf8) else {
            throw InvestmentError.invalid("无法读取已保存的行情凭据。")
        }
        return value
    }

    private func keys() -> [InvestmentQuoteSource: String] {
        var result: [InvestmentQuoteSource: String] = [:]
        for source in InvestmentQuoteSource.allCases {
            if let key = try? loadKey(for: source), !key.isEmpty {
                result[source] = key
            }
        }
        return result
    }

    func searchInstruments(_ search: InvestmentInstrumentSearch) async throws -> [InvestmentAsset] {
        let local = book.assets.values.filter(search.includes)
        if search.kind == .crypto {
            guard search.currency == .usd else { return [] }
            return try await searchCrypto(search, local: local)
        }
        let online = try await InvestmentQuoteProvider().searchInstruments(search, keys: keys())
        var results: [InvestmentAsset] = []
        for asset in local + online where !results.contains(where: { $0.matches(asset) && $0.name == asset.name }) {
            results.append(asset)
        }
        return results.sorted { lhs, rhs in
            let left = lhs.code == search.exactAsset.code || lhs.name == search.query
            let right = rhs.code == search.exactAsset.code || rhs.name == search.query
            return left == right ? lhs.code < rhs.code : left
        }
    }

    func watchQuotes(for asset: InvestmentAsset) async throws -> [InvestmentQuote] {
        try await InvestmentQuoteProvider().watchQuotes(for: asset, keys: keys())
    }

    private func searchCrypto(_ search: InvestmentInstrumentSearch, local: [InvestmentAsset]) async throws -> [InvestmentAsset] {
        let catalog: [InvestmentAsset]
        do {
            catalog = try await loadCryptoCatalog()
        } catch {
            try Task.checkCancellation()
            if let cached = cryptoCatalog { catalog = cached.entries }
            else if !local.isEmpty { catalog = [] }
            else { throw error }
        }
        try Task.checkCancellation()
        let code = search.exactAsset.code
        var seen = Set<String>()
        return (catalog.filter(search.includes) + local).filter { seen.insert($0.code).inserted }.sorted { lhs, rhs in
            let left = lhs.code == code ? 0 : lhs.code.hasPrefix(code) ? 1 : 2
            let right = rhs.code == code ? 0 : rhs.code.hasPrefix(code) ? 1 : 2
            return left == right ? lhs.code < rhs.code : left < right
        }
    }

    private func loadCryptoCatalog() async throws -> [InvestmentAsset] {
        if let cached = cryptoCatalog, Date.now.timeIntervalSince(cached.loadedAt) < 900 { return cached.entries }
        if let request = cryptoCatalogRequest { return try await request.value }
        let request = Task { try await InvestmentQuoteProvider().cryptoCatalog() }
        cryptoCatalogRequest = request
        defer { cryptoCatalogRequest = nil }
        let entries = try await request.value
        cryptoCatalog = (.now, entries)
        return entries
    }

    func searchContracts(_ query: String, basis: InvestmentContractBasis) async throws -> [InvestmentContractListing] {
        async let binance = contractCatalog(.binance, basis: basis)
        async let htx = contractCatalog(.htx, basis: basis)
        let (first, second) = await (binance, htx)
        try Task.checkCancellation()
        guard first != nil || second != nil else { throw InvestmentError.invalid("交易所合约目录暂不可用") }
        func normalized(_ value: String) -> String {
            String(value.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
        }
        let code = normalized(query)
        let matches = ((first ?? []) + (second ?? [])).filter {
            (!code.isEmpty && normalized($0.asset.code).contains(code)) || $0.asset.name.localizedCaseInsensitiveContains(query)
        }
        return matches.sorted { lhs, rhs in
            let left = normalized(lhs.asset.code), right = normalized(rhs.asset.code)
            if (left == code) != (right == code) { return left == code }
            if left.hasPrefix(code) != right.hasPrefix(code) { return left.hasPrefix(code) }
            let leftPerpetual = lhs.asset.name.hasSuffix("永续"), rightPerpetual = rhs.asset.name.hasSuffix("永续")
            if leftPerpetual != rightPerpetual { return leftPerpetual }
            return (left, lhs.asset.market) < (right, rhs.asset.market)
        }
    }

    private func contractCatalog(_ exchange: InvestmentContractExchange, basis: InvestmentContractBasis) async -> [InvestmentContractListing]? {
        if let cached = contractCatalogs[basis]?[exchange], Date.now.timeIntervalSince(cached.loadedAt) < 900 {
            return cached.entries
        }
        guard let entries = try? await InvestmentQuoteProvider().contractCatalog(exchange, basis: basis), !Task.isCancelled else {
            return nil
        }
        contractCatalogs[basis, default: [:]][exchange] = (.now, entries)
        return entries
    }

    var publicQuoteIDs: Set<UUID> {
        let supported = Set(book.assets.values.filter { $0.kind == .crypto || InvestmentContractExchange(asset: $0) != nil }.map(\.id))
        guard !supported.isEmpty else { return [] }
        let tracked = book.watched + book.plans.filter(\.enabled).compactMap(\.assetID)
        let held = book.accounts.flatMap { account -> [UUID] in
            guard account.type == .crypto, let ledger = try? book.ledger(account) else { return [] }
            return ledger.positions.compactMap { $0.value.quantity > 0 ? $0.key : nil }
        }
        return Set(tracked + held).intersection(supported)
    }

    func prepareSettlementQuote(_ token: InvestmentAsset) async {
        let revision = ledgerRevision
        guard book.quote(token.id)?.day != InvestmentBook.day(),
              let quote = try? await InvestmentQuoteProvider().coinbaseSpotUSDQuote(code: token.code),
              !Task.isCancelled, revision == ledgerRevision, book.asset(token.id) != nil,
              book.quote(token.id)?.day != quote.day else { return }
        try? update { $0.addQuotes([quote], assetID: token.id) }
    }

    func settleDuePlans() {
        guard book.plans.contains(where: { $0.enabled && $0.nextDay <= InvestmentBook.day() }) else { return }
        do { try update { $0.runPlans() } }
        catch { quoteStatus = error.localizedDescription }
    }

    func refreshIfNeeded() async {
        let today = InvestmentBook.day()
        let currencies = rateCurrencies
        let publicIDs = publicQuoteIDs
        let general = (configured || !currencies.isEmpty)
            && (lastAutomaticRefresh != today || !currencies.isSubset(of: lastAutomaticCurrencies))
        let publicDue = !publicIDs.isEmpty && (!publicIDs.isSubset(of: lastAutomaticPublicQuotes)
            || lastPublicQuoteRefresh.map { Date.now.timeIntervalSince($0) >= 300 } ?? true)
        guard !refreshing else { return }
        guard general || publicDue else {
            saveCompletedInvestmentMonths()
            return
        }
        if general {
            lastAutomaticRefresh = today
            lastAutomaticCurrencies = currencies
        }
        await refresh(publicQuotesOnly: !general)
        if Task.isCancelled, general { lastAutomaticRefresh = nil }
    }

    func refresh(publicQuotesOnly: Bool = false) async {
        guard loaded, !refreshing else { return }
        let revision = ledgerRevision
        func checkRefresh() throws {
            try Task.checkCancellation()
            guard ledgerRevision == revision else { throw CancellationError() }
        }
        refreshing = true
        defer {
            if !Task.isCancelled, ledgerRevision == revision { saveCompletedInvestmentMonths() }
            refreshing = false
        }
        do {
            let keys = publicQuotesOnly ? [:] : self.keys()
            let currencies = publicQuotesOnly ? [] : rateCurrencies
            let publicIDs = publicQuoteIDs
            guard !keys.isEmpty || !currencies.isEmpty || !publicIDs.isEmpty else {
                if publicQuotesOnly { return }
                quoteStatus = "请在投资记账设置中配置行情，或在标的详情录入报价。"
                return
            }
            let today = InvestmentBook.day()
            let yearStart = InvestmentBook.addDays(-375, to: today)
            let start = min(yearStart, book.earliest ?? yearStart)
            let ids = Set(book.watched + book.accounts.flatMap(\.events).compactMap(\.assetID) + book.plans.compactMap(\.assetID))
            let provider = InvestmentQuoteProvider()
            var prices: [UUID: [InvestmentQuote]] = [:]
            var rates: [InvestmentCurrency: [InvestmentQuote]] = [:]
            var failures: [String] = []
            for asset in ids.compactMap({ book.assets[$0] }).sorted(by: { $0.code < $1.code })
                where !keys.isEmpty && !asset.kind.isManual && (!asset.isHongKongEquity || asset.isStockConnect) {
                try checkRefresh()
                do {
                    let result = try await provider.history(asset: asset, start: start, through: today,
                        cached: book.quote(asset.id)?.day, keys: keys)
                    prices[asset.id] = result
                    if !publicIDs.contains(asset.id), let last = result.last, last.day < InvestmentBook.addDays(-7, to: today) {
                        failures.append(asset.code + "（报价未更新）")
                    }
                } catch {
                    try checkRefresh()
                    if !publicIDs.contains(asset.id) { failures.append(asset.code + "（" + error.localizedDescription + "）") }
                }
            }
            let publicAssets = publicIDs.compactMap { book.asset($0) }
            let contracts = publicAssets.filter { $0.kind == .cryptoContract }
            let byInstrument = Dictionary(grouping: contracts) { [$0.market, $0.basis.rawValue, $0.code] }
            for positions in byInstrument.values {
                guard let asset = positions.first else { continue }
                try checkRefresh()
                do {
                    let quote = try await provider.contractMark(asset)
                    for position in positions { prices[position.id] = [quote] }
                } catch {
                    try checkRefresh()
                    failures.append(asset.market + " " + asset.code + "（标记价格未更新）")
                }
            }
            let tokens = Set(publicAssets.filter { $0.kind == .crypto }.map(\.id)).union(contracts.compactMap(\.collateralAssetID))
            let usdtUSD = tokens.isEmpty ? nil : try? await provider.coinbaseSpotUSDQuote(code: "USDT")
            for id in tokens {
                guard let token = book.asset(id) else { continue }
                try checkRefresh()
                do {
                    let quote = try await provider.publicSpotUSDQuote(for: token, usdtUSD: usdtUSD)
                    prices[id, default: []].append(quote)
                } catch {
                    try checkRefresh()
                    if prices[id]?.last?.day != today, book.quote(id)?.day != today {
                        failures.append(token.code + "/USD（现货报价未更新）")
                    }
                }
            }
            var fallbackCurrencies = currencies
            if let key = keys[.twelveData] {
                for currency in currencies.sorted(by: { $0.rawValue < $1.rawValue }) {
                    try checkRefresh()
                    if let result = try? await provider.twelve(symbol: currency.rawValue + "/CNY", market: "",
                            currency: nil, start: start, end: today, key: key) {
                        rates[currency] = result
                        let cutoff = max(book.fx[currency]?.last?.day ?? start, InvestmentBook.addDays(-7, to: today))
                        if let last = result.last, last.day >= cutoff { fallbackCurrencies.remove(currency) }
                    }
                }
            }
            if !fallbackCurrencies.isEmpty {
                try checkRefresh()
                do {
                    let fallback = try await provider.ecbRates(for: fallbackCurrencies, start: start, end: today)
                    for (currency, values) in fallback {
                        if let last = values.last, rates[currency]?.last.map({ $0.day < last.day }) ?? true {
                            rates[currency] = values
                        }
                    }
                } catch {
                    try checkRefresh()
                }
            }
            for currency in currencies.subtracting(rates.keys) { failures.append(currency.rawValue + "/CNY") }
            try checkRefresh()
            guard publicQuotesOnly || self.keys() == keys else { return }
            try update { draft in
                for (id, values) in prices { draft.addQuotes(values, assetID: id) }
                for (currency, values) in rates { draft.fx[currency] = InvestmentBook.merge(draft.fx[currency] ?? [], values) }
                draft.runPlans(through: today)
            }
            if !publicIDs.isEmpty {
                lastPublicQuoteRefresh = .now
                lastAutomaticPublicQuotes = publicIDs
            }
            if failures.isEmpty {
                let sources = Set((Array(prices.values) + Array(rates.values)).compactMap { $0.last?.source })
                let status = prices.isEmpty ? "汇率已更新" : "行情已更新"
                quoteStatus = sources.isEmpty ? "暂无需要同步的标的" : status + " · " + sources.sorted().joined(separator: " / ")
            } else {
                quoteStatus = "部分行情不可用 · " + failures.joined(separator: "、")
            }
        } catch is CancellationError {
            return
        } catch {
            quoteStatus = error.localizedDescription
        }
    }

    private func saveCompletedInvestmentMonths() {
        guard loaded else { return }
        var draft = book
        guard draft.recordCompletedInvestmentMonths() else { return }
        do {
            try persist(draft)
            book = draft
        } catch {
            quoteStatus = "无法保存投资理财月末快照。"
        }
    }
}
