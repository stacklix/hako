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
    @Published var showsArchived = UserDefaults.standard.bool(forKey: "investment.showArchived") {
        didSet { UserDefaults.standard.set(showsArchived, forKey: "investment.showArchived") }
    }
    var visibleAccounts: [InvestmentAccount] { book.visibleAccounts(showArchived: showsArchived) }
    @Published var showsZeroPositions = UserDefaults.standard.bool(forKey: "investment.showZeroPositions") {
        didSet { UserDefaults.standard.set(showsZeroPositions, forKey: "investment.showZeroPositions") }
    }

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
    @Published private(set) var ledgerRevision = UUID()
    private var dailySnapshotTask: Task<Void, Never>?
    private var lastAutomaticRefresh: Date?
    private var lastAutomaticCurrencies: Set<InvestmentCurrency> = []
    private var lastPublicQuoteRefresh: Date?
    private var lastPublicHistoryDay: Date?
    private var lastAutomaticPublicQuotes: Set<UUID> = []
    private var cryptoCatalog: (loadedAt: Date, entries: [InvestmentAsset])?
    private var cryptoCatalogRequest: Task<[InvestmentAsset], Error>?
    private var selectedInstruments: [String: InvestmentAsset] = [:]
    private var contractCatalogs: [InvestmentContractBasis: [InvestmentContractExchange: (loadedAt: Date, entries: [InvestmentContractListing])]] = [:]
    var hasLoaded: Bool { loaded }
    var configured: Bool { !configuredSources.isEmpty }
    var canRefresh: Bool { configured || !rateCurrencies.isEmpty || !publicQuoteIDs.isEmpty }
    func entryEditorStore(book: InvestmentBook) -> InvestmentStore {
        let preview = InvestmentStore(authentication: authentication)
        preview.book = book
        preview.configuredSources = configuredSources
        preview.selectedInstruments = selectedInstruments
        preview.cryptoCatalog = cryptoCatalog
        preview.contractCatalogs = contractCatalogs
        // No server state/session is installed: an editor cannot write through this store.
        return preview
    }
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
        let validatedVersion = bookVersion
        try await validateCatalogChanges(draft, previous: book)
        while saving || loading { try await Task.sleep(for: .milliseconds(50)) }
        try Task.checkCancellation()
        guard validatedVersion == bookVersion else { throw InvestmentError.invalid("账本版本已变更，请核对后再保存。") }
        var dirty = serverState?.dirtyFrom
        if let previous = book.dailySnapshots?.through, let next = draft.dailySnapshots?.through, next < previous {
            let day = records.day.string(from: InvestmentBook.addDays(1, to: next))
            dirty = min(day, dirty ?? day)
        }
        // The API writes source records and derived snapshots separately. Prune only
        // snapshot references first; all account/holding/event deletions remain one input write.
        // Mark them dirty so a failed deletion can rebuild the retained account's history.
        let deletedAccounts = Set(book.accounts.map(\.id)).subtracting(draft.accounts.map(\.id))
        let deletedMonths = Set(book.balanceSheet?.investmentSnapshots.keys.map { $0 } ?? [])
            .subtracting(draft.balanceSheet?.investmentSnapshots.keys.map { $0 } ?? [])
        var cleanup = book
        var pruning = !deletedMonths.isEmpty
        if let histories = book.dailySnapshots?.accountValues,
           histories.keys.contains(where: { deletedAccounts.contains($0) }) {
            cleanup.dailySnapshots?.accountValues = histories.filter { !deletedAccounts.contains($0.key) }
            pruning = true
        }
        if pruning {
            let months = cleanup.balanceSheet?.investmentSnapshots.filter { !deletedMonths.contains($0.key) } ?? [:]
            cleanup.balanceSheet?.replaceInvestmentSnapshots(months)
            let remaining = Set(draft.accounts.flatMap(\.events).map(\.id))
            let first = book.accounts.flatMap(\.events).filter { !remaining.contains($0.id) }.map(\.day).min()
                ?? book.earliest
            if let first {
                let day = records.day.string(from: first)
                dirty = min(day, dirty ?? day)
            }
            try await write(cleanup, dirtyFrom: dirty, includeInputs: false, includeSnapshots: true)
        }
        draft.dailySnapshots = book.dailySnapshots
        draft.balanceSheet?.replaceInvestmentSnapshots(book.balanceSheet?.investmentSnapshots ?? [:])
        do { try await write(draft, dirtyFrom: dirty, includeInputs: true, includeSnapshots: false) }
        catch { scheduleDailySnapshots(); throw error }
        if scheduleSnapshots { scheduleDailySnapshots() }
    }

    func agentSnapshot() throws -> InvestmentAgentSnapshot {
        discardExpiredSession()
        guard loaded, let state = serverState, let context = serverContext, context == authentication.requestContext else {
            throw InvestmentError.invalid(loadError ?? "请先读取服务端投资账本。")
        }
        return InvestmentAgentSnapshot(book: book, session: ledgerRevision, generation: state.generation, revision: state.revision,
                                       dirtyFrom: state.dirtyFrom.flatMap(records.day.date(from:)), tables: state.tables)
    }

    var agentConversationKey: String {
        (authentication.serverURL + "\n" + authentication.username).consoleDigest
    }

    func commitAgent(_ proposal: InvestmentAgentProposal) async throws {
        while saving || loading { try await Task.sleep(for: .milliseconds(50)) }
        try Task.checkCancellation()
        let current = try agentSnapshot()
        guard current.session == proposal.session else { throw CancellationError() }
        guard current.generation == proposal.generation else { throw InvestmentAgentCommitError.stale }
        do {
            if proposal.snapshotsOnly {
                try await write(proposal.book, dirtyFrom: nil, includeInputs: true, includeSnapshots: true)
                snapshotSaveError = nil
            } else {
                let deletesHistory = proposal.actions.contains { $0.kind == .removeAccount || $0.kind == .removePosition }
                try await update(scheduleSnapshots: deletesHistory) { draft in
                    let live = try agentSnapshot()
                    guard live.session == proposal.session else { throw CancellationError() }
                    guard live.generation == proposal.generation else { throw InvestmentAgentCommitError.stale }
                    draft = proposal.book
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as InvestmentAgentCommitError {
            throw error
        } catch {
            if case .invalid(let message)? = error as? InvestmentError,
               message.contains("账本已重新读取") || message.contains("账本版本已变更") {
                throw InvestmentAgentCommitError.stale
            }
            throw InvestmentAgentCommitError.unverified
        }
    }

    func prepareAgentMarket(_ base: InvestmentAgentSnapshot) async throws -> InvestmentBook {
        while refreshing { try await Task.sleep(for: .milliseconds(150)) }
        try Task.checkCancellation()
        var prepared: InvestmentBook?
        await refreshQuotes(preview: { prepared = $0 })
        try Task.checkCancellation()
        let current = try agentSnapshot()
        guard current.session == base.session, current.generation == base.generation else { throw InvestmentAgentCommitError.stale }
        guard let prepared else { throw InvestmentError.invalid(quoteStatus.isEmpty ? "未找到可更新的行情。" : quoteStatus) }
        return prepared
    }

    func prepareAgentEntries(_ actions: [InvestmentAgentAction], from base: InvestmentAgentSnapshot) async throws -> InvestmentBook {
        var candidate = base.book
        for action in actions { try action.apply(to: &candidate) }
        try await validateCatalogChanges(candidate, previous: base.book)
        let contracts = candidate.assets.values.filter { asset in
            guard asset.kind == .cryptoContract else { return false }
            guard let original = base.book.asset(asset.id) else { return true }
            return original.code != asset.code || original.market != asset.market
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        for asset in contracts {
            try Task.checkCancellation()
            guard let exchange = InvestmentContractExchange(asset: asset) else {
                throw InvestmentError.invalid("请从交易所目录选择 U 本位或币本位合约，不能使用自定义代码代替行情合约。")
            }
            guard let entries = await contractCatalog(exchange, basis: asset.basis) else {
                throw InvestmentError.invalid("\(exchange.title) 合约目录暂不可用，尚未核实行情关联，请稍后重试。")
            }
            guard let listing = entries.first(where: { $0.asset.code == asset.code }) else {
                throw InvestmentError.invalid("\(exchange.title) 目录中没有合约 \(asset.code)。请用搜索结果中的真实代码，多空方向单独填写。")
            }
            try listing.validateSelection(asset, settlement: candidate.settlementUnit(for: asset))
            if let quote = try? await InvestmentQuoteProvider().contractMark(asset) {
                candidate.addQuotes([quote], assetID: asset.id)
            }
        }
        try Task.checkCancellation()
        let current = try agentSnapshot()
        guard current.session == base.session, current.generation == base.generation else { throw InvestmentAgentCommitError.stale }
        return candidate
    }

    private func validateCatalogChanges(_ candidate: InvestmentBook, previous: InvestmentBook) async throws {
        let changed = candidate.catalogAssetsRequiringValidation(comparedTo: previous)
        for asset in changed {
            try Task.checkCancellation()
            if asset.kind == .cryptoContract {
                guard let exchange = InvestmentContractExchange(asset: asset),
                      let entries = await contractCatalog(exchange, basis: asset.basis),
                      let listing = entries.first(where: { $0.asset.code == asset.code }) else {
                    throw InvestmentError.invalid("请从 HTX 或 BIN（Binance）目录选择真实永续合约；不支持交割合约，目录暂不可用时不能手工录入。")
                }
                try listing.validateSelection(asset, settlement: candidate.settlementUnit(for: asset))
            } else {
                let listed: InvestmentAsset
                if let selected = selectedInstruments[asset.catalogKey] { listed = selected }
                else {
                    let query = InvestmentInstrumentSearch(query: asset.code, kind: asset.kind, currency: asset.currency,
                                                           stockConnect: asset.isStockConnect)
                    let entries = try await searchInstruments(query)
                    let matches = entries.filter { $0.catalogKey == asset.catalogKey }
                    guard matches.count == 1, let selected = matches.first else {
                        throw InvestmentError.invalid("未找到唯一匹配的市场标的。请搜索并选择对应市场的真实代码，不能手工创建。")
                    }
                    listed = selected
                }
                try asset.validateCatalogIdentity(listed)
            }
        }
    }

    func prepareAgentSnapshots(_ base: InvestmentAgentSnapshot) async throws -> InvestmentBook {
        while refreshing { try await Task.sleep(for: .milliseconds(150)) }
        try Task.checkCancellation()
        var source = base.book
        // The page fills missing historical inputs before recalculating. Keep both steps
        // in memory here so the confirmation commits the inputs and snapshots together.
        await refreshQuotes(fullSnapshotHistory: true, preview: { source = $0 })
        try Task.checkCancellation()
        let refreshed = try agentSnapshot()
        guard refreshed.session == base.session, refreshed.generation == base.generation else { throw InvestmentAgentCommitError.stale }
        if let dirty = base.dirtyFrom { source.invalidateDailySnapshots(from: dirty) }
        let end = InvestmentBook.addDays(-1, to: InvestmentBook.day())
        source = try await calculatedSnapshots(source, through: end, rebuild: true)
        let current = try agentSnapshot()
        guard current.session == base.session, current.generation == base.generation else { throw InvestmentAgentCommitError.stale }
        return source
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
            let previous = output ? InvestmentServerRecords.ordered(state.tables[name] ?? []) : old[name] ?? []
            if replacement != previous || (output && dirtyFrom != state.dirtyFrom) {
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
            source = try await calculatedSnapshots(source, through: end, rebuild: rebuild)
            guard ledgerRevision == resetVersion else { throw CancellationError() }
            guard version == bookVersion else { continue }
            try await write(source, dirtyFrom: nil, includeInputs: false, includeSnapshots: true)
            snapshotSaveError = nil
            return book.dailySnapshotReport(through: end)
        }
        throw InvestmentError.invalid("账本正在更新，请稍后重新计算快照。")
    }

    private func calculatedSnapshots(_ source: InvestmentBook, through end: Date, rebuild: Bool) async throws -> InvestmentBook {
        let worker = Task.detached(priority: .utility) {
            var result = source
            if let snapshots = source.makeDailySnapshots(through: end, rebuild: rebuild) { result.dailySnapshots = snapshots }
            if source.earliest == nil { result.dailySnapshots = nil }
            _ = result.recordCompletedInvestmentMonths()
            return result
        }
        let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        return result
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
        if search.kind.requiresCatalog {
            let entries: [InvestmentAsset]
            if search.kind == .crypto {
                guard search.currency == .usd else { return [] }
                entries = try await loadCryptoCatalog().filter(search.includes)
            } else {
                entries = try await InvestmentQuoteProvider().searchInstruments(search, keys: keys())
            }
            for asset in entries { selectedInstruments[asset.catalogKey] = asset }
            return entries.sorted { lhs, rhs in
                let left = lhs.code == search.exactAsset.code || lhs.name == search.query
                let right = rhs.code == search.exactAsset.code || rhs.name == search.query
                return left == right ? (lhs.code, lhs.market) < (rhs.code, rhs.market) : left
            }
        }
        let local = book.assets.values.filter(search.includes)
        let online: [InvestmentAsset]
        do {
            online = try await InvestmentQuoteProvider().searchInstruments(search, keys: keys())
        } catch {
            try Task.checkCancellation()
            guard !local.isEmpty else { throw error }
            online = []
        }
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
        let request = try InvestmentContractSearch(query)
        let entries: [InvestmentContractListing]
        if let exchange = request.exchange {
            guard let listings = await contractCatalog(exchange, basis: basis) else {
                throw InvestmentError.invalid("\(exchange.title) 永续合约目录暂不可用，请稍后重试。")
            }
            entries = listings
        } else {
            async let binance = contractCatalog(.binance, basis: basis)
            async let htx = contractCatalog(.htx, basis: basis)
            let (first, second) = await (binance, htx)
            guard let first, let second else {
                throw InvestmentError.invalid("未能完整读取两家交易所的永续合约目录，请稍后重试，或在代码后指定 •HTX / •BIN 查询对应交易所。")
            }
            entries = first + second
        }
        try Task.checkCancellation()
        func normalized(_ value: String) -> String {
            String(value.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
        }
        let code = normalized(request.query)
        let matches = entries.filter {
            (!code.isEmpty && normalized($0.asset.code).contains(code)) || $0.asset.name.localizedCaseInsensitiveContains(request.query)
        }.map { listing in
            var asset = listing.asset
            asset.contractSide = request.side
            return InvestmentContractListing(asset: asset, settlementCode: listing.settlementCode)
        }
        return matches.sorted { lhs, rhs in
            let left = normalized(lhs.asset.code), right = normalized(rhs.asset.code)
            if (left == code) != (right == code) { return left == code }
            if left.hasPrefix(code) != right.hasPrefix(code) { return left.hasPrefix(code) }
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

    private func refreshQuotes(publicQuotesOnly: Bool = false, fullSnapshotHistory: Bool? = nil,
                               preview: ((InvestmentBook) -> Void)? = nil) async {
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
                            failures.append(asset.displayCode + "（报价未更新）")
                        }
                    } catch {
                        try checkRefresh()
                        if !publicIDs.contains(asset.id) { failures.append(asset.displayCode + "（" + error.localizedDescription + "）") }
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
                    failures.append(asset.displayCode + "（标记价格未更新）")
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
            let apply: (inout InvestmentBook) -> Void = { draft in
                for (id, values) in prices { draft.addQuotes(values, assetID: id) }
                for (currency, values) in rates { draft.addExchangeRates(values, for: currency) }
                draft.runPlans(through: today)
            }
            if let preview {
                var draft = book
                apply(&draft)
                preview(draft)
                return
            }
            try await update(scheduleSnapshots: !snapshotRefresh, apply)
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
