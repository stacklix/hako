import Combine
import Foundation

@MainActor
final class InvestmentStore: ObservableObject {
    static let shared = InvestmentStore()

    private(set) var bookVersion = UUID()
    @Published private(set) var book = InvestmentBook() {
        didSet { bookVersion = UUID() }
    }
    @Published private(set) var loadError: String?
    @Published private(set) var configuredSources: Set<InvestmentQuoteSource> = []
    @Published private(set) var refreshing = false
    @Published private(set) var quoteStatus = ""
    @Published private(set) var snapshotSaveError: String?

    private let authentication: any AuthenticatedServerAccess
    private let records = InvestmentServerRecords()
    private var serverState: InvestmentServerState?
    private var serverContext: String?
    private var authenticationChanges: AnyCancellable?
    @Published private(set) var loading = false
    @Published private(set) var saving = false

    init(authentication: (any AuthenticatedServerAccess)? = nil) {
        let access = authentication ?? AuthenticatedServerService.shared
        self.authentication = access
        authenticationChanges = access.changes.sink { [weak self] in
            Task { @MainActor in self?.discardExpiredSession() }
        }
    }
    private let secrets = SecureStorage.namespace("me.stackli.hako.investment")
    private var loaded = false
    private var ledgerRevision = UUID()
    private var dailySnapshotTask: Task<Void, Never>?
    private var lastAutomaticRefresh: Date?
    private var lastAutomaticCurrencies: Set<InvestmentCurrency> = []
    private var lastPublicQuoteRefresh: Date?
    private var lastPublicHistoryDay: Date?
    private var lastAutomaticPublicQuotes: Set<UUID> = []
    private var cryptoCatalog: (loadedAt: Date, entries: [InvestmentAsset])?
    private var cryptoCatalogRequest: Task<[InvestmentAsset], Error>?
    private var contractCatalogs: [InvestmentContractBasis: [InvestmentContractExchange: (loadedAt: Date, entries: [InvestmentContractListing])]] = [:]
    var hasLoaded: Bool { loaded }
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

    private static let bookPath = "/api/v1/investment/book"

    private func discardExpiredSession() {
        guard let serverContext, serverContext != authentication.requestContext else { return }
        dailySnapshotTask?.cancel()
        ledgerRevision = UUID()
        self.serverContext = nil
        serverState = nil
        loaded = false
        book = InvestmentBook()
        lastAutomaticRefresh = nil
        lastAutomaticCurrencies = []
        lastPublicQuoteRefresh = nil
        lastPublicHistoryDay = nil
        lastAutomaticPublicQuotes = []
    }

    func load(force: Bool = false) async {
        discardExpiredSession()
        guard !loading, !saving, force || !loaded else { return }
        loading = true
        defer { loading = false }
        do {
            await authentication.restore()
            guard authentication.authenticated else {
                throw InvestmentError.invalid("请先在 Hako 设置中登录服务端。")
            }
            let context = authentication.requestContext
            let data = try await authentication.send(Self.bookPath, method: "GET", body: nil, logSource: .hako)
            try Task.checkCancellation()
            guard context == authentication.requestContext else { throw CancellationError() }
            let state = try JSONDecoder().decode(InvestmentServerState.self, from: data)
            if !loaded || serverState?.generation != state.generation {
                book = try records.decode(state)
            }
            serverContext = context
            serverState = state
            loaded = true
            loadError = nil
            configuredSources = Set(keys().keys)
            scheduleDailySnapshots()
        } catch is CancellationError {
            return
        } catch let error as ServerHTTPError where error.status == 404 {
            loadError = "当前 Hako 服务端版本还未提供投资账本接口。"
        } catch {
            if loaded { quoteStatus = error.localizedDescription }
            else { loadError = error.localizedDescription }
        }
    }

    func exportLedger() async throws -> Data {
        await authentication.restore()
        guard authentication.authenticated else {
            throw InvestmentError.invalid("请先在 Hako 设置中登录服务端。")
        }
        let context = authentication.requestContext
        do {
            let data = try await authentication.send("/api/v1/investment/export", method: "GET", body: nil, logSource: .hako)
            try Task.checkCancellation()
            guard context == authentication.requestContext else { throw CancellationError() }
            guard data.starts(with: [0x50, 0x4B, 0x03, 0x04]) else {
                throw InvestmentError.invalid("服务端返回的账本压缩包无效。")
            }
            return data
        } catch let error as ServerHTTPError where error.status == 404 {
            throw InvestmentError.invalid("请先升级 Hako 服务端，再导出账本。")
        } catch let error as ServerHTTPError where error.code == "storage_unavailable" {
            throw InvestmentError.invalid("暂时无法读取服务端账本，请稍后重试。")
        }
    }

    func update(scheduleSnapshots: Bool = true, _ change: (inout InvestmentBook) throws -> Void) async throws {
        while saving || loading { try await Task.sleep(for: .milliseconds(50)) }
        try Task.checkCancellation()
        try checkWritable()
        var draft = book
        try change(&draft)
        var dirty = serverState?.dirtyFrom
        if let previous = book.dailySnapshots?.through, let next = draft.dailySnapshots?.through, next < previous {
            let day = records.day.string(from: InvestmentBook.addDays(1, to: next))
            dirty = min(day, dirty ?? day)
        }
        draft.dailySnapshots = book.dailySnapshots
        try await write(draft, dirtyFrom: dirty, includeInputs: true, includeSnapshots: false)
        if scheduleSnapshots { scheduleDailySnapshots() }
    }

    private func checkWritable() throws {
        discardExpiredSession()
        guard loaded, serverState != nil else {
            throw InvestmentError.invalid(loadError ?? "请先读取服务端投资账本。")
        }
        guard !saving, !loading else { throw InvestmentError.invalid("账本正在同步，请稍后重试。") }
    }

    private func write(_ draft: InvestmentBook, dirtyFrom: String?, includeInputs: Bool, includeSnapshots: Bool) async throws {
        try checkWritable()
        guard var state = serverState else { return }
        let context = authentication.requestContext
        let old = try records.encode(book, revision: state.revision)
        let next = try records.encode(draft, revision: state.revision)
        var changes: InvestmentServerTables = [:]
        for name in InvestmentServerRecords.names {
            let output = InvestmentServerRecords.snapshotTables.contains(name)
            guard output ? includeSnapshots : includeInputs else { continue }
            let replacement = next[name] ?? []
            if replacement != old[name] || (output && dirtyFrom != state.dirtyFrom) {
                changes[name] = replacement
            }
        }
        let through = includeSnapshots ? draft.dailySnapshots.map { records.day.string(from: $0.through) } : state.through
        guard !changes.isEmpty || dirtyFrom != state.dirtyFrom || through != state.through else { return }
        var body: [String: Any] = ["generation": state.generation, "tables": changes]
        body["dirtyFrom"] = dirtyFrom.map { $0 as Any } ?? NSNull()
        body["through"] = through.map { $0 as Any } ?? NSNull()
        saving = true
        defer { saving = false }
        do {
            let data = try await authentication.send(Self.bookPath, method: "PUT", body: body, logSource: .hako)
            guard context == authentication.requestContext else { throw CancellationError() }
            let confirmed = try JSONDecoder().decode(InvestmentServerState.self, from: data)
            state.generation = confirmed.generation
            state.revision = confirmed.revision
            state.dirtyFrom = confirmed.dirtyFrom
            state.through = confirmed.through
            state.tables.merge(confirmed.tables) { _, incoming in incoming }
            book = try records.decode(state)
            serverState = state
        } catch let error as ServerHTTPError where error.status == 409 {
            saving = false
            await load(force: true)
            let refreshed = serverState?.generation != state.generation
            throw InvestmentError.invalid(refreshed ? "账本已重新读取。请核对后再保存。" : "账本版本已变更，请重新读取后再保存。")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            saving = false
            await load(force: true)
            if let confirmed = serverState, context == authentication.requestContext, confirmed.generation > state.generation,
               confirmed.dirtyFrom == dirtyFrom, confirmed.through == through,
               changes.allSatisfy({ name, rows in
                   let saved = (confirmed.tables[name] ?? []).map { row in
                       row.filter { $0.key != "revision" || rows.first?["revision"] != nil }
                   }
                   return InvestmentServerRecords.ordered(saved) == rows
               }) {
                return
            }
            throw error
        }
    }

    func saveDailySnapshots(rebuild: Bool = false) async throws -> InvestmentDailySnapshotReport {
        await load()
        try checkWritable()
        let resetVersion = ledgerRevision
        let end = InvestmentBook.addDays(-1, to: InvestmentBook.day())
        for _ in 0..<3 {
            try Task.checkCancellation()
            guard ledgerRevision == resetVersion else { throw CancellationError() }
            var source = book
            let dirty = serverState?.dirtyFrom.flatMap(records.day.date(from:))
            if let dirty { source.invalidateDailySnapshots(from: dirty) }
            if !rebuild, dirty == nil, !source.needsDailySnapshots(through: end) {
                return source.dailySnapshotReport(through: end)
            }
            let version = bookVersion
            let valuationSource = source
            let worker = Task.detached(priority: .utility) { valuationSource.makeDailySnapshots(through: end, rebuild: rebuild) }
            let snapshots = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            try Task.checkCancellation()
            guard ledgerRevision == resetVersion else { throw CancellationError() }
            guard version == bookVersion else { continue }
            if let snapshots { source.dailySnapshots = snapshots }
            if source.earliest == nil { source.dailySnapshots = nil }
            _ = source.recordCompletedInvestmentMonths()
            try await write(source, dirtyFrom: nil, includeInputs: false, includeSnapshots: true)
            snapshotSaveError = nil
            return book.dailySnapshotReport(through: end)
        }
        throw InvestmentError.invalid("账本正在更新，请稍后重新计算快照。")
    }

    private func scheduleDailySnapshots() {
        let end = InvestmentBook.addDays(-1, to: InvestmentBook.day())
        guard book.needsDailySnapshots(through: end) || serverState?.dirtyFrom != nil else { return }
        dailySnapshotTask?.cancel()
        dailySnapshotTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
                try await self?.refreshSnapshotHistory(fullHistory: false)
                _ = try await self?.saveDailySnapshots()
            } catch is CancellationError {
                return
            } catch {
                self?.snapshotSaveError = error.localizedDescription
            }
        }
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
        try? await update { $0.addQuotes([quote], assetID: token.id) }
    }

    func settleDuePlans() async {
        guard book.plans.contains(where: { $0.enabled && $0.nextDay <= InvestmentBook.day() }) else { return }
        do { try await update { $0.runPlans() } }
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
            return
        }
        if general {
            lastAutomaticRefresh = today
            lastAutomaticCurrencies = currencies
        }
        await refresh(publicQuotesOnly: !general)
        if Task.isCancelled, general { lastAutomaticRefresh = nil }
    }

    func refreshSnapshotHistory(fullHistory: Bool = true) async throws {
        if fullHistory { await load(force: true) }
        let revision = ledgerRevision
        while refreshing {
            try await Task.sleep(for: .milliseconds(150))
        }
        try Task.checkCancellation()
        guard ledgerRevision == revision else { throw CancellationError() }
        await refreshQuotes(fullSnapshotHistory: fullHistory)
        try Task.checkCancellation()
        guard ledgerRevision == revision else { throw CancellationError() }
    }

    func refresh(publicQuotesOnly: Bool = false) async {
        await load(force: true)
        await refreshQuotes(publicQuotesOnly: publicQuotesOnly)
    }

    private func refreshQuotes(publicQuotesOnly: Bool = false, fullSnapshotHistory: Bool? = nil) async {
        guard loaded, !refreshing else { return }
        let revision = ledgerRevision
        func checkRefresh() throws {
            try Task.checkCancellation()
            guard ledgerRevision == revision else { throw CancellationError() }
        }
        refreshing = true
        defer {
            refreshing = false
        }
        do {
            let today = InvestmentBook.day()
            let closedDay = InvestmentBook.addDays(-1, to: today)
            let snapshotRefresh = fullSnapshotHistory != nil
            var snapshotRequests: InvestmentSnapshotQuoteRequests?
            if let fullSnapshotHistory {
                var source = book
                if let dirty = serverState?.dirtyFrom.flatMap(records.day.date(from:)) {
                    source.invalidateDailySnapshots(from: dirty)
                }
                guard let window = source.dailyQuoteWindow(through: closedDay, fullHistory: fullSnapshotHistory) else { return }
                let valuationSource = source
                let worker = Task.detached(priority: .utility) { valuationSource.missingDailyMarketData(in: window) }
                snapshotRequests = await withTaskCancellationHandler {
                    await worker.value
                } onCancel: { worker.cancel() }
                try checkRefresh()
                if let snapshotRequests, snapshotRequests.assets.isEmpty, snapshotRequests.rates.isEmpty { return }
            }
            let keys = publicQuotesOnly ? [:] : self.keys()
            let currencies = publicQuotesOnly ? [] : rateCurrencies
            let publicIDs = snapshotRefresh ? [] : publicQuoteIDs
            guard !keys.isEmpty || !currencies.isEmpty || !publicIDs.isEmpty else {
                if publicQuotesOnly { return }
                quoteStatus = "请在投资记账设置中配置行情，或在标的详情录入报价。"
                return
            }
            let refreshPublicHistory = !publicQuotesOnly || lastPublicHistoryDay != today
            let yearStart = InvestmentBook.addDays(-375, to: today)
            let start = min(yearStart, book.earliest ?? yearStart)
            let ids = snapshotRequests.map { Set($0.assets.keys) }
                ?? Set(book.watched + book.accounts.flatMap(\.events).compactMap(\.assetID) + book.plans.compactMap(\.assetID))
            let provider = InvestmentQuoteProvider()
            var prices: [UUID: [InvestmentQuote]] = [:]
            var rates: [InvestmentCurrency: [InvestmentQuote]] = [:]
            var failures: [String] = []
            for asset in ids.compactMap({ book.assets[$0] }).sorted(by: { $0.code < $1.code })
                where !keys.isEmpty && !asset.kind.isManual && (!asset.isHongKongEquity || asset.isStockConnect) &&
                    (!snapshotRefresh || asset.kind != .crypto) {
                for request in snapshotRequests?.assets[asset.id] ?? [start...today] {
                    try checkRefresh()
                    do {
                        let result = try await provider.history(asset: asset, start: request.lowerBound, through: request.upperBound,
                            cached: snapshotRefresh ? nil : book.quote(asset.id)?.day, keys: keys)
                        prices[asset.id, default: []].append(contentsOf: result)
                        if !snapshotRefresh, !publicIDs.contains(asset.id), let last = result.last,
                           last.day < InvestmentBook.addDays(-7, to: today) {
                            failures.append(asset.code + "（报价未更新）")
                        }
                    } catch {
                        try checkRefresh()
                        if !publicIDs.contains(asset.id) { failures.append(asset.code + "（" + error.localizedDescription + "）") }
                    }
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
            if refreshPublicHistory {
                let history = try await cryptoHistory(through: closedDay, provider: provider,
                                                      missing: snapshotRequests?.assets)
                try checkRefresh()
                for (id, quotes) in history { prices[id, default: []].append(contentsOf: quotes) }
            }
            let rateWindows = snapshotRequests?.rates ?? Dictionary(uniqueKeysWithValues: currencies.map { ($0, [start...today]) })
            var fallbackRequests: [ClosedRange<Date>: Set<InvestmentCurrency>] = [:]
            for (currency, windows) in rateWindows.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                for window in windows {
                    try checkRefresh()
                    if let key = keys[.twelveData],
                       let result = try? await provider.twelve(symbol: currency.rawValue + "/CNY", market: "",
                            currency: nil, start: window.lowerBound, end: window.upperBound, key: key) {
                        rates[currency, default: []].append(contentsOf: result)
                        let cutoff = snapshotRefresh ? window.upperBound :
                            max(book.fx[currency]?.last?.day ?? start, InvestmentBook.addDays(-7, to: today))
                        if let last = result.last, last.day >= cutoff { continue }
                    }
                    fallbackRequests[window, default: []].insert(currency)
                }
            }
            for (window, fallbackCurrencies) in fallbackRequests.sorted(by: { $0.key.lowerBound < $1.key.lowerBound }) {
                try checkRefresh()
                do {
                    let fallback = try await provider.ecbRates(for: fallbackCurrencies,
                        start: window.lowerBound, end: window.upperBound)
                    for (currency, values) in fallback {
                        if snapshotRefresh {
                            rates[currency] = InvestmentBook.merge(values, rates[currency] ?? [])
                        } else if let last = values.last, rates[currency]?.last.map({ $0.day < last.day }) ?? true {
                            rates[currency] = values
                        }
                    }
                } catch {
                    try checkRefresh()
                }
            }
            for currency in Set(rateWindows.keys).subtracting(rates.keys) { failures.append(currency.rawValue + "/CNY") }
            try checkRefresh()
            guard publicQuotesOnly || self.keys() == keys else { return }
            try await update(scheduleSnapshots: !snapshotRefresh) { draft in
                for (id, values) in prices { draft.addQuotes(values, assetID: id) }
                for (currency, values) in rates { draft.addExchangeRates(values, for: currency) }
                draft.runPlans(through: today)
            }
            if refreshPublicHistory, !snapshotRefresh { lastPublicHistoryDay = today }
            if !publicIDs.isEmpty {
                lastPublicQuoteRefresh = .now
                lastAutomaticPublicQuotes = publicIDs
            }
            if failures.isEmpty {
                let sources = Set((Array(prices.values) + Array(rates.values)).compactMap { $0.last?.source })
                let status = prices.isEmpty ? "汇率已更新" : "行情已更新"
                quoteStatus = sources.isEmpty ? "暂无需要同步的标的" : status + " · " + sources.sorted().joined(separator: " / ")
            } else {
                quoteStatus = "部分行情不可用 · " + Set(failures).sorted().joined(separator: "、")
            }
        } catch is CancellationError {
            return
        } catch {
            quoteStatus = error.localizedDescription
        }
    }

    private func cryptoHistory(through end: Date, provider: InvestmentQuoteProvider,
                               missing: [UUID: [ClosedRange<Date>]]?) async throws -> [UUID: [InvestmentQuote]] {
        let book = self.book
        let limit = InvestmentBook.addDays(-374, to: end)
        var firstDates: [UUID: Date] = [:]
        if missing == nil {
            for account in book.accounts where account.type == .crypto {
                for event in account.events {
                    guard event.day <= end, let asset = book.asset(event.assetID),
                          asset.kind == .crypto || InvestmentContractExchange(asset: asset) != nil else { continue }
                    let date = max(event.day, limit)
                    firstDates[asset.id] = min(firstDates[asset.id] ?? date, date)
                    if let collateral = asset.collateralAssetID {
                        firstDates[collateral] = min(firstDates[collateral] ?? date, date)
                    }
                }
            }
        }
        let requestedRanges = missing ?? firstDates.mapValues { [$0...end] }
        let requests = requestedRanges.flatMap { id, ranges -> [(asset: InvestmentAsset, range: ClosedRange<Date>)] in
            guard let asset = book.asset(id),
                  asset.kind == .crypto || InvestmentContractExchange(asset: asset) != nil else { return [] }
            let closes = Set((book.quotes[id] ?? []).filter { $0.isDailyClose == true }.map(\.day))
            return ranges.compactMap { range in
                var start = range.lowerBound
                while start <= range.upperBound, closes.contains(start) { start = InvestmentBook.addDays(1, to: start) }
                return start <= range.upperBound ? (asset, start...range.upperBound) : nil
            }
        }
        var spotRanges: [ClosedRange<Date>] = []
        for range in requests.filter({ $0.asset.kind == .crypto }).map(\.range).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            InvestmentBook.addQuoteWindow(range, to: &spotRanges)
        }
        var usdtUSD: [Date: Decimal] = [:]
        for range in spotRanges {
            try Task.checkCancellation()
            let quotes = try? await provider.coinbaseUSDDailyQuotes(for: "USDT", from: range.lowerBound, through: range.upperBound)
            for quote in quotes ?? [] { usdtUSD[quote.day] = quote.price }
        }
        var result: [UUID: [InvestmentQuote]] = [:]
        for (asset, range) in requests {
            try Task.checkCancellation()
            let (start, end) = (range.lowerBound, range.upperBound)
            if asset.kind == .crypto {
                let prices = try? await provider.binanceSpotDailyQuotes(for: asset.code, from: start, through: end, usdtUSD: usdtUSD)
                if let prices, !prices.isEmpty {
                    result[asset.id, default: []].append(contentsOf: prices)
                } else if let prices = try? await provider.coinbaseUSDDailyQuotes(for: asset.code, from: start, through: end) {
                    result[asset.id, default: []].append(contentsOf: prices)
                }
            } else {
                if let quotes = try? await provider.contractDailyQuotes(for: asset, from: start, through: end) {
                    result[asset.id, default: []].append(contentsOf: quotes)
                }
            }
        }
        return result
    }
}
