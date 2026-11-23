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
    @Published private(set) var cacheError: String?
    private var cacheWasCleared = false
    private var lastServerReadSucceeded = false
    private let diskCache = InvestmentDiskCache.shared
    var dataCacheScope: String { (authentication.serverURL + "\n" + authentication.username).consoleDigest }
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
    private var lastAutomaticMarketQuotes: Set<UUID> = []
    private var lastPublicQuoteRefresh: Date?
    private var lastPublicHistoryDay: Date?
    private var lastAutomaticPublicQuotes: Set<UUID> = []
    private var cryptoCatalog: (loadedAt: Date, entries: [InvestmentAsset])?
    private var cryptoCatalogRequest: Task<[InvestmentAsset], Error>?
    private var selectedInstruments: [String: InvestmentAsset] = [:]
    var hasLoaded: Bool { loaded }
    var configured: Bool { !configuredSources.isEmpty }
    var marketQuoteIDs: Set<UUID> { Set(book.assets.values.filter { $0.usesEastmoneyMarketData || $0.usesUSEquityClose }.map(\.id)) }
    var canRefresh: Bool { configured || !marketQuoteIDs.isEmpty || !rateCurrencies.isEmpty || !publicQuoteIDs.isEmpty }
    func entryEditorStore(book: InvestmentBook) -> InvestmentStore {
        let preview = InvestmentStore(authentication: authentication)
        preview.book = book
        preview.configuredSources = configuredSources
        preview.selectedInstruments = selectedInstruments
        preview.cryptoCatalog = cryptoCatalog
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
        lastAutomaticMarketQuotes = []
        lastPublicQuoteRefresh = nil
        lastPublicHistoryDay = nil
        lastAutomaticPublicQuotes = []
    }

    func load(force: Bool = false) async {
        discardExpiredSession()
        guard !loading, !saving, force || !loaded || cacheWasCleared else { return }
        loading = true
        defer { loading = false }
        do {
            await authentication.restore()
            guard authentication.authenticated else {
                throw InvestmentError.invalid("请先在 Hako 设置中登录服务端。")
            }
            let context = authentication.requestContext
            let scope = dataCacheScope
            if (!loaded || !force), !cacheWasCleared,
               let cached = try? await diskCache.load(scope: scope),
               let restored = try? records.decode(cached), context == authentication.requestContext {
                book = try await restoringMarketQuotes(in: restored, scope: scope); serverState = cached; serverContext = context
                loaded = true; loadError = nil; configuredSources = Set(keys().keys)
                if !force { scheduleDailySnapshots(); return }
            }
            lastServerReadSucceeded = false
            let data = try await authentication.send(Self.bookPath, method: "GET", body: nil, logSource: .hako)
            try Task.checkCancellation()
            guard context == authentication.requestContext else { throw CancellationError() }
            let state = try JSONDecoder().decode(InvestmentServerState.self, from: data)
            if !loaded || serverState?.generation != state.generation {
                book = try await restoringMarketQuotes(in: records.decode(state), scope: scope)
            }
            serverContext = context
            serverState = state
            loaded = true
            lastServerReadSucceeded = true
            cacheWasCleared = false
            loadError = nil
            await persistCache(state, scope: scope)
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

    func loadForSynchronization() async throws {
        lastServerReadSucceeded = false
        await load(force: true)
        try Task.checkCancellation()
        guard lastServerReadSucceeded else {
            throw InvestmentError.invalid(loadError ?? (quoteStatus.isEmpty ? "本次未能读取服务端投资账本，请检查网络后重试。" : quoteStatus))
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
        if cacheWasCleared {
            await load(force: true)
            guard lastServerReadSucceeded else { throw InvestmentError.invalid("请恢复服务端连接后再保存。") }
        }
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
        if let first = draft.snapshotInputChange(comparedTo: try serverState.map(records.decode) ?? book) {
            draft.invalidateDailySnapshots(from: first)
            let day = records.day.string(from: first)
            dirty = min(day, dirty ?? day)
        }
        if let previous = book.dailySnapshots?.through, let next = draft.dailySnapshots?.through, next < previous {
            let day = records.day.string(from: InvestmentBook.addDays(1, to: next))
            dirty = min(day, dirty ?? day)
        }
        // The API writes source records and derived snapshots separately. Prune only
        // snapshot references first; all account/holding/event deletions remain one input write.
        // Mark them dirty so a failed deletion can rebuild the retained account's history.
        let deletedAccounts = Set(book.accounts.map(\.id)).subtracting(draft.accounts.map(\.id))
        var cleanup = book
        var pruning = false
        if let histories = book.dailySnapshots?.accountValues,
           histories.keys.contains(where: { deletedAccounts.contains($0) }) {
            cleanup.dailySnapshots?.accountValues = histories.filter { !deletedAccounts.contains($0.key) }
            pruning = true
        }
        if pruning {
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
        try await refreshQuotes(preview: { prepared = $0 })
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
        try Task.checkCancellation()
        let current = try agentSnapshot()
        guard current.session == base.session, current.generation == base.generation else { throw InvestmentAgentCommitError.stale }
        return candidate
    }

    private func validateCatalogChanges(_ candidate: InvestmentBook, previous: InvestmentBook) async throws {
        let changed = candidate.catalogAssetsRequiringValidation(comparedTo: previous)
        for asset in changed {
            try Task.checkCancellation()
            do {
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
        try await refreshQuotes(fullSnapshotHistory: true, preview: { source = $0 })
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
        if includeInputs { try records.validateEventInputs(draft, comparedTo: book) }
        let old = try records.encode(records.decode(state), revision: state.revision)
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
        try InvestmentWriteValidation.validate(generation: state.generation, revision: state.revision,
            dirtyFrom: dirtyFrom, through: through, changes: changes, current: state.tables)
        if includeInputs { try records.validateLedgers(next, comparedTo: old) }
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
                await persistCache(state, scope: dataCacheScope)
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

    func inspectData() async throws -> InvestmentDataReport {
        await authentication.restore()
        guard authentication.authenticated else { throw InvestmentError.invalid("请先在 Hako 设置中登录服务端。") }
        let context = authentication.requestContext
        let data = try await authentication.send(Self.bookPath, method: "GET", body: nil, logSource: .hako)
        guard context == authentication.requestContext else { throw CancellationError() }
        let source = try records.decode(JSONDecoder().decode(InvestmentServerState.self, from: data))
        let worker = Task.detached(priority: .utility) { source.inspectData() }
        let report = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        guard context == authentication.requestContext else { throw CancellationError() }
        return report
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
            if let dirty {
                source.invalidateDailySnapshots(from: dirty)
            }
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
            return result
        }
        let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        return result
    }

    private func scheduleDailySnapshots() {
        let end = InvestmentBook.addDays(-1, to: InvestmentBook.day())
        dailySnapshotTask?.cancel()
        guard book.needsDailySnapshots(through: end) || serverState?.dirtyFrom != nil else {
            dailySnapshotTask = nil
            return
        }
        dailySnapshotTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
                guard let self else { return }
                guard self.book.needsDailySnapshots(through: end) || self.serverState?.dirtyFrom != nil else { return }
                try await self.refreshSnapshotHistory(fullHistory: false)
                _ = try await self.saveDailySnapshots()
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

    var publicQuoteIDs: Set<UUID> {
        let supported = Set(book.assets.values.filter { $0.kind == .crypto }.map(\.id))
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
        do { try await processDuePlans() }
        catch is CancellationError { return }
        catch { quoteStatus = error.localizedDescription }
    }

    private func processDuePlans() async throws {
        while saving || loading { try await Task.sleep(for: .milliseconds(50)) }
        try Task.checkCancellation()
        guard book.plans.contains(where: { $0.enabled && $0.nextDay <= InvestmentBook.day() }) else { return }
        var preview = book
        guard preview.runPlans() else { return }
        try await update { $0.runPlans() }
    }

    func refreshAndSettlePlans() async throws {
        while refreshing { try await Task.sleep(for: .milliseconds(150)) }
        try Task.checkCancellation()
        try await refreshQuotes()
        try await processDuePlans()
    }

    func refreshIfNeeded() async {
        let today = InvestmentBook.day()
        let currencies = rateCurrencies
        let publicIDs = publicQuoteIDs
        let marketIDs = marketQuoteIDs
        let general = (configured || !currencies.isEmpty || !marketIDs.isEmpty)
            && (lastAutomaticRefresh != today || !currencies.isSubset(of: lastAutomaticCurrencies)
                || !marketIDs.isSubset(of: lastAutomaticMarketQuotes))
        let publicDue = !publicIDs.isEmpty && (!publicIDs.isSubset(of: lastAutomaticPublicQuotes)
            || lastPublicQuoteRefresh.map { Date.now.timeIntervalSince($0) >= 300 } ?? true)
        guard !refreshing else { return }
        guard general || publicDue else {
            return
        }
        if general {
            lastAutomaticRefresh = today
            lastAutomaticCurrencies = currencies
            lastAutomaticMarketQuotes = marketIDs
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
        try await refreshQuotes(fullSnapshotHistory: fullHistory)
        try Task.checkCancellation()
        guard ledgerRevision == revision else { throw CancellationError() }
    }

    // Disk -> confirmed server observations -> API for uncovered ranges. Newly
    // fetched observations are saved on both tiers without creating transactions.
    func holdingPriceHistory(assetID: UUID, from start: Date, through end: Date) async throws -> InvestmentPriceHistoryResult {
        discardExpiredSession()
        if cacheWasCleared { await load(force: true) }
        guard loaded else { throw InvestmentError.invalid("请先加载投资账本。") }
        guard let asset = book.asset(assetID), asset.supportsPriceHistory else { return InvestmentPriceHistoryResult(quotes: [], warning: nil) }
        let revision = ledgerRevision
        let credentials = keys()
        let first = asset.usesUSEquityClose ? InvestmentBook.addDays(-1, to: start) : start
        guard first <= end else { return InvestmentPriceHistoryResult(quotes: [], warning: nil) }
        let scope = dataCacheScope, today = InvestmentBook.day()
        if let cached = try? await diskCache.history(scope: scope, asset: asset, start: first, end: end, today: today) {
            let quotes = InvestmentBook.merge(cached, book.quotes[assetID] ?? []).filter { $0.day >= first && $0.day <= end }
            return InvestmentPriceHistoryResult(quotes: quotes, warning: nil)
        }
        let key = InvestmentDiskCache.historyKey(asset)
        let saved = try await diskCache.marketQuotes(scope: scope, key: key)
        let localQuotes = InvestmentBook.merge(saved, book.quotes[assetID] ?? []).filter {
            $0.isDailyClose == true && $0.source != "手动录入"
        }
        if try await diskCache.missingWindows(scope: scope, key: key, start: first, end: end,
            today: today, observations: localQuotes).isEmpty {
            return InvestmentPriceHistoryResult(quotes: localQuotes, warning: nil)
        }
        // A disk miss must consult the server before making a provider request.
        await load(force: true)
        guard loaded, scope == dataCacheScope, ledgerRevision == revision else { throw CancellationError() }
        guard lastServerReadSucceeded else { throw InvestmentError.invalid("无法确认服务端历史数据，请恢复连接后重试。") }
        let provider = InvestmentQuoteProvider()
        var result = InvestmentBook.merge(saved, book.quotes[assetID] ?? []).filter {
            $0.isDailyClose == true && $0.source != "手动录入"
        }
        var fetched = saved
        var firstFailure: String?
        let missing = try await diskCache.missingWindows(scope: scope, key: key, start: first, end: end,
            today: today, observations: result)
        for window in missing.flatMap({ InvestmentHistoryRange.quoteWindows(from: $0.lowerBound, through: $0.upperBound) }).reversed() {
            try Task.checkCancellation()
            do {
                let values: [InvestmentQuote]
                do {
                    if asset.kind == .crypto {
                        values = try await provider.cryptoPriceHistory(code: asset.code, from: window.lowerBound, through: window.upperBound)
                    } else {
                        values = try await provider.history(asset: asset, start: window.lowerBound, through: window.upperBound,
                            cached: nil, keys: credentials)
                    }
                } catch InvestmentError.noMarketData(_) { values = [] }
                try Task.checkCancellation()
                guard ledgerRevision == revision, scope == dataCacheScope else { throw CancellationError() }
                try await diskCache.saveHistory(scope: scope, asset: asset, start: window.lowerBound,
                    end: window.upperBound, today: today, quotes: values)
                result = InvestmentBook.merge(result, values)
                fetched = InvestmentBook.merge(fetched, values)
            } catch {
                try Task.checkCancellation()
                if firstFailure == nil { firstFailure = error.localizedDescription }
            }
            try Task.checkCancellation()
            guard ledgerRevision == revision, book.asset(assetID) == asset, keys() == credentials else { throw CancellationError() }
        }
        if !fetched.isEmpty {
            do { try await update { $0.addQuotes(fetched, assetID: assetID) } }
            catch {
                try Task.checkCancellation()
                var local = book
                local.addQuotes(fetched, assetID: assetID)
                book = local
                firstFailure = firstFailure ?? "行情已保存到本机，服务端同步失败：" + error.localizedDescription
            }
        }
        return InvestmentPriceHistoryResult(quotes: result, warning: firstFailure.map { "部分历史行情查询失败：" + $0 })
    }

    private func restoringMarketQuotes(in source: InvestmentBook, scope: String) async throws -> InvestmentBook {
        var restored = source
        for asset in source.assets.values where !asset.kind.isManual {
            let saved = try await diskCache.marketQuotes(scope: scope, key: InvestmentDiskCache.historyKey(asset))
            let known = Set((source.quotes[asset.id] ?? []).filter { $0.price > 0 && $0.isDailyClose != false }.map(\.day))
            restored.addQuotes(saved.filter { !known.contains($0.day) }, assetID: asset.id)
        }
        for currency in InvestmentCurrency.allCases where currency != .cny {
            let saved = try await diskCache.marketQuotes(scope: scope, key: InvestmentDiskCache.rateKey(currency))
            let known = Set((source.fx[currency] ?? []).filter { $0.price > 0 && $0.isDailyClose != false }.map(\.day))
            restored.addExchangeRates(saved.filter { !known.contains($0.day) }, for: currency)
        }
        guard scope == dataCacheScope else { throw CancellationError() }
        return restored
    }

    private func persistCache(_ state: InvestmentServerState, scope: String) async {
        do { try await diskCache.save(state, scope: scope); cacheError = nil }
        catch { cacheError = "本机缓存写入失败，请检查可用存储空间。" }
    }

    func managedData(fromServer: Bool) async throws -> InvestmentServerState? {
        await authentication.restore()
        guard authentication.authenticated else { throw InvestmentError.invalid("请先登录服务端。") }
        let context = authentication.requestContext, scope = dataCacheScope
        if !fromServer { return try await diskCache.snapshot(scope: scope) }
        let data = try await authentication.send(Self.bookPath, method: "GET", body: nil, logSource: .hako)
        guard context == authentication.requestContext else { throw CancellationError() }
        return try JSONDecoder().decode(InvestmentServerState.self, from: data)
    }

    func localCacheBytes() async throws -> Int64 { try await diskCache.byteCount(scope: dataCacheScope) }

    func deleteLocalData(category: InvestmentDataCategory? = nil, rows: [InvestmentCachedRow]? = nil) async throws {
        try await diskCache.remove(scope: dataCacheScope, category: category, rows: rows)
        cacheWasCleared = true
    }

    func refresh(publicQuotesOnly: Bool = false) async {
        await load(force: true)
        do {
            try await refreshQuotes(publicQuotesOnly: publicQuotesOnly)
            try await processDuePlans()
        } catch is CancellationError { return }
        catch { quoteStatus = error.localizedDescription }
    }

    private func refreshQuotes(publicQuotesOnly: Bool = false, fullSnapshotHistory: Bool? = nil,
                               preview: ((InvestmentBook) -> Void)? = nil) async throws {
        guard loaded, !refreshing else { return }
        guard lastServerReadSucceeded else {
            throw InvestmentError.invalid("服务端暂不可用，继续使用本地行情与汇率；确认服务端缺失后才会查询行情接口。")
        }
        let scope = dataCacheScope
        let revision = ledgerRevision
        func checkRefresh() throws {
            try Task.checkCancellation()
            guard ledgerRevision == revision, scope == dataCacheScope else { throw CancellationError() }
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
            guard !keys.isEmpty || !marketQuoteIDs.isEmpty || !currencies.isEmpty || !publicIDs.isEmpty else {
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
                where !publicQuotesOnly && (asset.usesEastmoneyMarketData || asset.usesUSEquityClose || !keys.isEmpty) && !asset.kind.isManual && (!asset.isHongKongEquity || asset.isStockConnect) &&
                    (!snapshotRefresh || asset.kind != .crypto) {
                let key = InvestmentDiskCache.historyKey(asset)
                let saved = try await diskCache.marketQuotes(scope: scope, key: key)
                let existing = book.quotes[asset.id] ?? []
                let known = Set(existing.filter { $0.price > 0 && $0.isDailyClose != false }.map(\.day))
                prices[asset.id] = saved.filter { !known.contains($0.day) }
                let observations = InvestmentBook.merge(saved, existing)
                let requested = snapshotRequests?.assets[asset.id] ?? [start...today]
                for range in requested {
                    let requests = try await diskCache.missingWindows(scope: scope, key: key,
                        start: range.lowerBound, end: range.upperBound, today: today, observations: observations)
                    for request in requests.flatMap({ InvestmentHistoryRange.quoteWindows(from: $0.lowerBound, through: $0.upperBound) }) {
                        try checkRefresh()
                        do {
                            let result: [InvestmentQuote]
                            do {
                                result = try await HakoExecutionDiagnostics.measure("读取行情 · " + asset.displayCode,
                                    success: InvestmentQuoteProvider.quoteSummary) {
                                    try await provider.history(asset: asset, start: request.lowerBound, through: request.upperBound,
                                        cached: nil, keys: keys)
                                }
                            } catch InvestmentError.noMarketData(_) { result = [] }
                            try checkRefresh()
                            // Persist downloaded data before attempting any server write.
                            try await diskCache.saveHistory(scope: scope, asset: asset, start: request.lowerBound,
                                end: request.upperBound, today: today, quotes: result)
                            prices[asset.id] = InvestmentBook.merge(prices[asset.id] ?? [], result)
                        } catch {
                            try checkRefresh()
                            if !publicIDs.contains(asset.id) { failures.append(asset.displayCode + "（" + error.localizedDescription + "）") }
                        }
                    }
                }
            }
            let publicAssets = publicIDs.compactMap { book.asset($0) }
            let tokens = Set(publicAssets.map(\.id))
            let usdtUSD = tokens.isEmpty ? nil : try? await HakoExecutionDiagnostics.measure("读取现货美元报价 · USDT",
                success: { InvestmentQuoteProvider.quoteSummary([$0]) }) { try await provider.coinbaseSpotUSDQuote(code: "USDT") }
            for id in tokens {
                guard let token = book.asset(id) else { continue }
                try checkRefresh()
                do {
                    let quote = try await HakoExecutionDiagnostics.measure("读取现货美元报价 · " + token.code,
                        success: { InvestmentQuoteProvider.quoteSummary([$0]) }) {
                        try await provider.publicSpotUSDQuote(for: token, usdtUSD: usdtUSD)
                    }
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
            let rateCurrenciesToCheck = Set(snapshotRequests?.rates.keys.map { $0 } ?? Array(currencies))
            for currency in rateCurrenciesToCheck.sorted(by: { $0.rawValue < $1.rawValue }) {
                let key = InvestmentDiskCache.rateKey(currency)
                let saved = try await diskCache.marketQuotes(scope: scope, key: key)
                let existing = book.fx[currency] ?? []
                let known = Set(existing.filter { $0.price > 0 && $0.isDailyClose != false }.map(\.day))
                rates[currency] = saved.filter { !known.contains($0.day) }
                let observations = InvestmentBook.merge(saved, existing)
                for range in snapshotRequests?.rates[currency] ?? [start...today] {
                    let missing = try await diskCache.missingWindows(scope: scope, key: key,
                        start: range.lowerBound, end: range.upperBound, today: today, observations: observations)
                    for window in missing.flatMap({ InvestmentHistoryRange.quoteWindows(from: $0.lowerBound, through: $0.upperBound) }) {
                        try checkRefresh()
                        do {
                            let values: [InvestmentQuote]
                            if let credential = keys[.twelveData] {
                                do {
                                    values = try await HakoExecutionDiagnostics.measure("读取汇率 · Twelve Data · " + currency.rawValue + "/CNY",
                                        success: InvestmentQuoteProvider.quoteSummary) {
                                        try await provider.twelve(symbol: currency.rawValue + "/CNY", market: "", currency: nil,
                                            start: window.lowerBound, end: window.upperBound, key: credential)
                                    }
                                } catch InvestmentError.noMarketData(_) { values = [] }
                                catch {
                                    try checkRefresh()
                                    values = try await provider.ecbRates(for: [currency], start: window.lowerBound, end: window.upperBound)[currency] ?? []
                                }
                            } else {
                                values = try await provider.ecbRates(for: [currency], start: window.lowerBound, end: window.upperBound)[currency] ?? []
                            }
                            try checkRefresh()
                            try await diskCache.saveMarketHistory(scope: scope, key: key, start: window.lowerBound,
                                end: window.upperBound, today: today, quotes: values)
                            rates[currency] = InvestmentBook.merge(rates[currency] ?? [], values)
                        } catch {
                            try checkRefresh()
                            failures.append(currency.rawValue + "/CNY（" + error.localizedDescription + "）")
                        }
                    }
                }
            }
            try checkRefresh()
            guard publicQuotesOnly || self.keys() == keys else { return }
            let apply: (inout InvestmentBook) -> Void = { draft in
                for (id, values) in prices { draft.addQuotes(values, assetID: id) }
                for (currency, values) in rates { draft.addExchangeRates(values, for: currency) }
                if !snapshotRefresh { draft.runPlans(through: today) }
            }
            if let preview {
                var draft = book
                apply(&draft)
                preview(draft)
                return
            }
            do { try await update(scheduleSnapshots: !snapshotRefresh, apply) }
            catch {
                try Task.checkCancellation()
                guard scope == dataCacheScope else { throw CancellationError() }
                book = try await restoringMarketQuotes(in: book, scope: scope)
                throw InvestmentError.invalid("行情与汇率已保存本机，服务端同步失败：" + error.localizedDescription)
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
            throw CancellationError()
        } catch {
            quoteStatus = error.localizedDescription
            throw error
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
                          asset.kind == .crypto else { continue }
                    let date = max(event.day, limit)
                    firstDates[asset.id] = min(firstDates[asset.id] ?? date, date)

                }
            }
        }
        let requestedRanges = missing ?? firstDates.mapValues { [$0...end] }
        let requests = requestedRanges.flatMap { id, ranges -> [(asset: InvestmentAsset, range: ClosedRange<Date>)] in
            guard let asset = book.asset(id),
                  asset.kind == .crypto else { return [] }
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
            let quotes = try? await HakoExecutionDiagnostics.measure("读取历史美元报价 · USDT",
                success: InvestmentQuoteProvider.quoteSummary) {
                try await provider.coinbaseUSDDailyQuotes(for: "USDT", from: range.lowerBound, through: range.upperBound)
            }
            try Task.checkCancellation()
            for quote in quotes ?? [] { usdtUSD[quote.day] = quote.price }
        }
        var result: [UUID: [InvestmentQuote]] = [:]
        for (asset, range) in requests {
            try Task.checkCancellation()
            let (start, end) = (range.lowerBound, range.upperBound)
            if asset.kind == .crypto {
                let prices = try? await HakoExecutionDiagnostics.measure("读取历史行情 · Binance · " + asset.code,
                    success: InvestmentQuoteProvider.quoteSummary) {
                    try await provider.binanceSpotDailyQuotes(for: asset.code, from: start, through: end, usdtUSD: usdtUSD)
                }
                try Task.checkCancellation()
                if let prices, !prices.isEmpty {
                    result[asset.id, default: []].append(contentsOf: prices)
                } else if let prices = try? await HakoExecutionDiagnostics.measure("读取历史行情 · Coinbase · " + asset.code,
                    success: InvestmentQuoteProvider.quoteSummary, operation: {
                    try await provider.coinbaseUSDDailyQuotes(for: asset.code, from: start, through: end)
                }) {
                    result[asset.id, default: []].append(contentsOf: prices)
                }
            }
            try Task.checkCancellation()
        }
        return result
    }
}
