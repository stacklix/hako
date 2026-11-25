import Combine
import Foundation

@MainActor
final class InvestmentStore: ObservableObject {
    static let shared = InvestmentStore()

    private(set) var bookVersion = UUID()
    private(set) var presentation = InvestmentPresentation(book: InvestmentBook())
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
    @Published var insuranceGainBasis = InvestmentInsuranceGainBasis(rawValue:
        UserDefaults.standard.string(forKey: "investment.insuranceGainBasis") ?? "") ?? .cashValue {
        didSet { UserDefaults.standard.set(insuranceGainBasis.rawValue, forKey: "investment.insuranceGainBasis") }
    }

    private let authentication: any AuthenticatedServerAccess
    private let records = InvestmentServerRecords()
    private var serverState: InvestmentServerState?
    private var serverContext: String?
    private var loadedScope: String?
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
        let scopeChanged = loadedScope.map { $0 != dataCacheScope } ?? false
        let sessionChanged = serverContext.map { $0 != authentication.requestContext } ?? false
        let signedOut = loadedScope != nil && (authentication.logoutPending || (!authentication.authenticated && !authentication.hasSavedSession))
        guard scopeChanged || sessionChanged || signedOut else { return }
        dailySnapshotTask?.cancel()
        ledgerRevision = UUID()
        self.serverContext = nil
        loadedScope = nil
        serverState = nil
        lastServerReadSucceeded = false
        loaded = false
        presentation = InvestmentPresentation(book: InvestmentBook())
        book = InvestmentBook()
        lastAutomaticRefresh = nil
        lastAutomaticCurrencies = []
        lastAutomaticMarketQuotes = []
        lastPublicQuoteRefresh = nil
        lastPublicHistoryDay = nil
        lastAutomaticPublicQuotes = []
    }

    func load(force: Bool = false, scheduleSnapshots: Bool = true) async {
        discardExpiredSession()
        guard !loading, !saving, force || !loaded || cacheWasCleared else { return }
        loading = true
        defer { loading = false }
        do {
            let scope = dataCacheScope
            let restoration = Task { await authentication.restore() }
            if !loaded, !cacheWasCleared, let cached = try? await diskCache.restoredBook(scope: scope) {
                // A local saved session is required before exposing account data.
                if !authentication.authenticated && !authentication.hasSavedSession { await restoration.value }
                if scope == dataCacheScope, !authentication.logoutPending,
                   authentication.authenticated || authentication.hasSavedSession {
                    try await publish(cached.book, scope: scope)
                    serverState = cached.state; loadedScope = scope
                    loaded = true; loadError = nil
                }
            }
            await restoration.value
            guard authentication.authenticated else {
                throw InvestmentError.invalid("请先在 Hako 设置中登录服务端。")
            }
            let context = authentication.requestContext
            guard scope == dataCacheScope else { throw CancellationError() }
            if loaded { serverContext = context }
            configuredSources = Set(keys().keys)
            if loaded, !force {
                if scheduleSnapshots { scheduleDailySnapshots() }
                return
            }
            lastServerReadSucceeded = false
            let data = try await authentication.send(Self.bookPath, method: "GET", body: nil, logSource: .hako)
            try Task.checkCancellation()
            guard context == authentication.requestContext else { throw CancellationError() }
            let state = try await Task.detached { try JSONDecoder().decode(InvestmentServerState.self, from: data) }.value
            if !loaded || (serverState?.generation != state.generation || serverState?.revision != state.revision) {
                let decoded = try await Task.detached { try InvestmentServerRecords().decode(state) }.value
                try await publish(try await restoringMarketQuotes(in: decoded, scope: scope), context: context)
            } else if presentation.day != InvestmentBook.day() {
                try await publish(book, context: context)
            }
            serverContext = context
            loadedScope = scope
            serverState = state
            loaded = true
            lastServerReadSucceeded = true
            cacheWasCleared = false
            loadError = nil
            await persistCache(state, scope: scope)
            configuredSources = Set(keys().keys)
            if scheduleSnapshots { scheduleDailySnapshots() }
        } catch is CancellationError {
            return
        } catch let error as ServerHTTPError where error.status == 404 {
            loadError = "当前 Hako 服务端版本还未提供投资账本接口。"
        } catch {
            if loaded { quoteStatus = error.localizedDescription }
            else { loadError = error.localizedDescription }
        }
    }

    private func publish(_ source: InvestmentBook, context: String? = nil, scope: String? = nil) async throws {
        let prepared = await HakoExecutionDiagnostics.measure("计算账户与持仓汇总", success: { _ in "已准备账户、持仓与组合汇总。" }) {
            await Task.detached(priority: .userInitiated) { InvestmentPresentation(book: source) }.value
        }
        if let context, context != authentication.requestContext { throw CancellationError() }
        if let scope {
            guard scope == dataCacheScope, !authentication.logoutPending,
                  authentication.authenticated || authentication.hasSavedSession else { throw CancellationError() }
        }
        presentation = prepared
        book = source
    }

    func loadForSynchronization() async throws {
        dailySnapshotTask?.cancel()
        lastServerReadSucceeded = false
        await load(force: true, scheduleSnapshots: false)
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
            await load(force: true, scheduleSnapshots: scheduleSnapshots)
            guard lastServerReadSucceeded else { throw InvestmentError.invalid("请恢复服务端连接后再保存。") }
        }
        while saving || loading { try await Task.sleep(for: .milliseconds(50)) }
        try Task.checkCancellation()
        try checkWritable()
        var draft = book
        try change(&draft)
        if let state = serverState {
            for asset in draft.assets.values where book.assets[asset.id] == nil && !asset.kind.isManual && (draft.quotes[asset.id]?.isEmpty ?? true) {
                draft.addQuotes(try records.sharedQuotes(for: asset, in: state), assetID: asset.id)
            }
        }
        let validatedVersion = bookVersion
        try await HakoExecutionDiagnostics.measure("校验标的变更") {
            try await validateCatalogChanges(draft, previous: book)
        }
        while saving || loading { try await Task.sleep(for: .milliseconds(50)) }
        try Task.checkCancellation()
        guard validatedVersion == bookVersion else { throw InvestmentError.invalid("账本版本已变更，请核对后再保存。") }
        var dirty = serverState?.dirtyFrom
        let snapshotSource = draft, priorState = serverState, priorBook = book
        let firstChanged: Date? = try await HakoExecutionDiagnostics.measure("检查历史快照影响范围", success: {
            $0.map { "需要从 " + InvestmentText.date($0) + " 重新计算快照。" } ?? "无须重算历史快照。"
        }) {
            try await Task.detached {
                snapshotSource.snapshotInputChange(comparedTo: try priorState.map { try InvestmentServerRecords().decode($0) } ?? priorBook)
            }.value
        }
        guard validatedVersion == bookVersion else { throw InvestmentError.invalid("账本版本已变更，请核对后再保存。") }
        if let first = firstChanged {
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
        catch {
            if scheduleSnapshots { scheduleDailySnapshots() }
            throw error
        }
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
                    let entries = try await searchInstruments(query, consolidateUSListings: false)
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
        saving = true
        defer { saving = false }
        let current = book, originalState = state
        let prepared: InvestmentPreparedWrite = try await HakoExecutionDiagnostics.measure("编码账本并比对变化", success: {
            "已校验账本；\($0.delta.count) 类数据有变化。"
        }) {
            try await Task.detached(priority: .userInitiated) {
                try InvestmentPreparedWrite(draft: draft, current: current, state: originalState,
                    dirtyFrom: dirtyFrom, includeInputs: includeInputs, includeSnapshots: includeSnapshots)
            }.value
        }
        guard context == authentication.requestContext else { throw CancellationError() }
        let changes = prepared.changes, through = prepared.through
        guard !changes.isEmpty || dirtyFrom != state.dirtyFrom || through != state.through else {
            HakoExecutionDiagnostics.record("保存投资账本", detail: "账本无变化，无须提交服务器。")
            return
        }
        let body: [String: Any] = try HakoExecutionDiagnostics.measure("准备账本同步请求") {
            let encodedDelta = try JSONEncoder().encode(prepared.delta)
            var body: [String: Any] = ["generation": state.generation, "revision": state.revision,
                                      "changes": try JSONSerialization.jsonObject(with: encodedDelta)]
            body["dirtyFrom"] = dirtyFrom.map { $0 as Any } ?? NSNull()
            body["through"] = through.map { $0 as Any } ?? NSNull()
            return body
        }
        do {
            let data = try await HakoExecutionDiagnostics.measure("提交账本变化") {
                try await authentication.send(Self.bookPath + "/changes", method: "POST", body: body, logSource: .hako)
            }
            guard context == authentication.requestContext else { throw CancellationError() }
            let previousState = state
            let response = try HakoExecutionDiagnostics.measure("解析服务器同步结果") {
                try JSONDecoder().decode(InvestmentDeltaResponse.self, from: data)
            }
            if response.reloadRequired {
                let marketOnly = !prepared.delta.isEmpty && prepared.delta.keys.allSatisfy {
                    ["market_daily_prices", "market_daily_fx"].contains($0)
                }
                if !marketOnly || response.generation == previousState.generation {
                    // Keep the confirmed ledger edit visible even if the following
                    // market reload fails. Its older revision forces a later reread.
                    var partial = try response.applying(to: previousState)
                    partial.revision = previousState.revision
                    let pending = partial
                    let decoded = try await HakoExecutionDiagnostics.measure("解码已确认账本") {
                        try await Task.detached { try InvestmentServerRecords().decode(pending) }.value
                    }
                    try await publish(decoded, context: context)
                    serverState = pending
                    await persistCache(pending, scope: dataCacheScope)
                }
                saving = false
                await load(force: true, scheduleSnapshots: false)
                return
            }
            let confirmed = try await HakoExecutionDiagnostics.measure("合并服务器确认记录") {
                try await Task.detached { try response.applying(to: previousState) }.value
            }
            state.generation = confirmed.generation
            state.revision = confirmed.revision
            state.dirtyFrom = confirmed.dirtyFrom
            state.through = confirmed.through
            state.tables.merge(confirmed.tables) { _, incoming in incoming }
            let confirmedState = state
            let decoded = try await HakoExecutionDiagnostics.measure("解码已确认账本") {
                try await Task.detached { try InvestmentServerRecords().decode(confirmedState) }.value
            }
            try await publish(decoded, context: context)
            serverState = state
            await persistCache(state, scope: dataCacheScope)
        } catch let error as ServerHTTPError where error.status == 409 {
            saving = false
            await load(force: true, scheduleSnapshots: false)
            let refreshed = serverState?.generation != state.generation
            throw InvestmentError.invalid(refreshed ? "账本已重新读取。请核对后再保存。" : "账本版本已变更，请重新读取后再保存。")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            saving = false
            await load(force: true, scheduleSnapshots: false)
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

    func searchInstruments(_ search: InvestmentInstrumentSearch, consolidateUSListings: Bool = true) async throws -> [InvestmentAsset] {
        if search.kind.requiresCatalog {
            let entries: [InvestmentAsset]
            if search.kind == .crypto {
                guard search.currency == .usd else { return [] }
                entries = try await loadCryptoCatalog().filter(search.includes)
            } else {
                entries = try await InvestmentQuoteProvider().searchInstruments(search, keys: keys(),
                                                                              consolidateUSListings: consolidateUSListings)
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
        let target = book.assets.values.first(where: { $0.matches(asset) }) ?? asset
        let today = InvestmentBook.day(), start = InvestmentBook.addDays(-14, to: InvestmentBook.day())
        let scope = dataCacheScope, credentials = keys()
        if let cached = try await diskCache.history(scope: scope, asset: target, start: start, end: today, today: today),
           let latest = cached.last, latest.day >= start { return cached }
        if let state = serverState {
            let shared = try records.sharedQuotes(for: target, in: state).filter { $0.day >= start && $0.day <= today }
            let required = target.kind == .crypto ? today : target.lastClosedMarketDay(at: .now)
            if let latest = shared.last, latest.day >= required { return shared }
        }
        let quotes = try await MarketAPIRequestContext.$reason.withValue("新增关注报价校验") {
            try await InvestmentQuoteProvider().watchQuotes(for: target, keys: credentials, through: today)
        }
        try Task.checkCancellation()
        guard scope == dataCacheScope, credentials == keys() else { throw CancellationError() }
        // Public spot fallback is not proof that the historical range was queried successfully.
        if quotes.contains(where: { $0.isDailyClose == true }) {
            try await diskCache.saveHistory(scope: scope, asset: target, start: start, end: today, today: today, quotes: quotes)
        }
        return quotes
    }

    func prepareEntryValuation(for asset: InvestmentAsset, account: InvestmentAccount) async throws
        -> (quotes: [InvestmentQuote], rates: [InvestmentCurrency: [InvestmentQuote]]) {
        while loading { try await Task.sleep(for: .milliseconds(50)) }
        try Task.checkCancellation()
        let scope = dataCacheScope, context = authentication.requestContext
        let target = book.assets.values.first { $0.matches(asset) } ?? asset
        let needsQuote = !target.kind.isManual && book.quote(target.id) == nil
        let currencies = Set([account.currency] + (asset.isStockConnect ? [.hkd] : [])).subtracting([.cny])
            .filter { book.rateToCNY($0, on: InvestmentBook.day()) == nil }
        guard needsQuote || !currencies.isEmpty else { return ([], [:]) }
        guard lastServerReadSucceeded else { throw InvestmentError.invalid("请先恢复服务端连接，再保存新持仓。") }
        var quotes: [InvestmentQuote] = []
        var rates: [InvestmentCurrency: [InvestmentQuote]] = [:]
        let today = InvestmentBook.day(), provider = InvestmentQuoteProvider()
        if needsQuote {
            let key = "latest|" + target.catalogKey
            if let saved = try await diskCache.marketQuotes(scope: scope, key: key).last(where: { $0.day <= today && $0.price > 0 }) {
                quotes = [saved]
            } else if let state = serverState,
                      let shared = try records.sharedQuotes(for: target, in: state).last(where: {
                          $0.day <= today && $0.day >= (target.kind == .crypto ? today : target.lastClosedMarketDay(at: .now))
                      }) {
                quotes = [shared]
            } else {
                let quote = try await MarketAPIRequestContext.$reason.withValue("保存持仓补查最新报价") {
                    try await provider.latestQuote(for: target, keys: keys())
                }
                quotes = [quote]
                // A latest-price lookup is not evidence of historical coverage.
                try await diskCache.saveMarketHistory(scope: scope, key: key, start: quote.day, end: quote.day, today: today, quotes: quotes)
            }
        }
        var missing = Set<InvestmentCurrency>()
        for currency in currencies {
            if let saved = try await diskCache.marketQuotes(scope: scope, key: InvestmentDiskCache.rateKey(currency))
                .last(where: { $0.day <= today && $0.price > 0 }) { rates[currency] = [saved] }
            else { missing.insert(currency) }
        }
        if !missing.isEmpty {
            let fetched = try await provider.ecbRates(for: missing, start: InvestmentBook.addDays(-14, to: today), end: today)
            for currency in missing {
                guard let quote = fetched[currency]?.last else { throw InvestmentError.invalid("暂未取得估值所需汇率，请稍后重试保存。") }
                rates[currency] = [quote]
                try await diskCache.saveMarketHistory(scope: scope, key: InvestmentDiskCache.rateKey(currency),
                    start: quote.day, end: quote.day, today: today, quotes: [quote])
            }
        }
        try Task.checkCancellation()
        guard scope == dataCacheScope, context == authentication.requestContext else { throw CancellationError() }
        return (quotes, rates)
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
              let quote = try? await InvestmentQuoteProvider().publicSpotUSDQuote(for: token),
              !Task.isCancelled, revision == ledgerRevision, book.asset(token.id) != nil,
              book.quote(token.id)?.day != quote.day else { return }
        try? await update { $0.addQuotes([quote], assetID: token.id) }
    }

    func settleDuePlans() async {
        do { try await processDuePlans() }
        catch is CancellationError { return }
        catch { quoteStatus = error.localizedDescription }
    }

    private func processDuePlans(scheduleSnapshots: Bool = true) async throws {
        while saving || loading { try await Task.sleep(for: .milliseconds(50)) }
        try Task.checkCancellation()
        let end = InvestmentBook.addDays(-1, to: InvestmentBook.day())
        guard book.plans.contains(where: { $0.enabled && $0.nextDay <= end }) else { return }
        var preview = book
        guard preview.runPlans(through: end) else { return }
        try await update(scheduleSnapshots: scheduleSnapshots) {
            $0.runPlans(through: end)
        }
    }

    func settleHistoricalPlans() async throws {
        while refreshing { try await Task.sleep(for: .milliseconds(150)) }
        try Task.checkCancellation()
        let priorRuns = book.planRuns
        try await HakoExecutionDiagnostics.measure("补记历史定投流水", success: { _ in book.planReport(since: priorRuns).message }) {
            try await processDuePlans(scheduleSnapshots: false)
        }
    }

    func refreshAndSettlePlans(reuseDailyCryptoQuotes: Bool = false) async throws {
        if refreshing {
            try await HakoExecutionDiagnostics.measure("等待行情刷新结束") {
                while refreshing { try await Task.sleep(for: .milliseconds(150)) }
            }
        }
        try Task.checkCancellation()
        try await refreshQuotes(reuseDailyCryptoQuotes: reuseDailyCryptoQuotes)
        let priorRuns = book.planRuns
        try await HakoExecutionDiagnostics.measure("检查并结算剩余定投", success: { _ in book.planReport(since: priorRuns).message }) {
            try await processDuePlans()
        }
    }

    func refreshIfNeeded(checkUnconfirmedRates: Bool = false) async {
        let today = InvestmentBook.day()
        let currencies = rateCurrencies
        let previous = InvestmentBook.weekdayMarketDate(on: InvestmentBook.addDays(-1, to: today))
        let unfinishedRates = checkUnconfirmedRates && book.earliest.map { $0 <= previous } == true &&
            currencies.contains { currency in
                !(book.fx[currency] ?? []).contains { $0.day == previous && $0.price > 0 && $0.isDailyClose == true }
            }
        let publicIDs = publicQuoteIDs
        let marketIDs = marketQuoteIDs
        let general = (configured || !currencies.isEmpty || !marketIDs.isEmpty)
            && (unfinishedRates || lastAutomaticRefresh != today || !currencies.isSubset(of: lastAutomaticCurrencies)
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

    func refreshSnapshotHistory(fullHistory: Bool = true, includePlans: Bool = false, recentDays: Int? = nil,
                                includeClosedMarkets: Bool = false) async throws {
        if fullHistory { await load(force: true) }
        let revision = ledgerRevision
        while refreshing {
            try await Task.sleep(for: .milliseconds(150))
        }
        try Task.checkCancellation()
        guard ledgerRevision == revision else { throw CancellationError() }
        let first = recentDays.map { InvestmentBook.addDays(-max(1, $0), to: InvestmentBook.day()) }
        try await refreshQuotes(fullSnapshotHistory: fullHistory, includeHistoricalPlans: includePlans,
                                historyNotBefore: first, includeClosedMarkets: includeClosedMarkets)
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
        for window in InvestmentHistoryRange.quoteWindows(for: missing).reversed() {
            try Task.checkCancellation()
            do {
                let values: [InvestmentQuote]
                do {
                    if asset.kind == .crypto {
                        values = try await provider.cryptoPriceHistory(code: asset.code, from: window.lowerBound, through: window.upperBound)
                    } else {
                        values = try await MarketAPIRequestContext.$reason.withValue("持仓价格走势图") {
                            try await provider.history(asset: asset, start: window.lowerBound, through: window.upperBound,
                                cached: nil, keys: credentials)
                        }
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
                try await publish(local, context: authentication.requestContext)
                firstFailure = firstFailure ?? "行情已保存到本机，服务端同步失败：" + error.localizedDescription
            }
        }
        return InvestmentPriceHistoryResult(quotes: result, warning: firstFailure.map { "部分历史行情查询失败：" + $0 })
    }

    private func restoringMarketQuotes(in source: InvestmentBook, scope: String) async throws -> InvestmentBook {
        let restored = try await diskCache.restoringMarketQuotes(in: source, scope: scope)
        guard scope == dataCacheScope else { throw CancellationError() }
        return restored
    }

    private func persistCache(_ state: InvestmentServerState, scope: String) async {
        do {
            try await HakoExecutionDiagnostics.measure("保存本地账本缓存") { try await diskCache.save(state, scope: scope) }
            cacheError = nil
        }
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
                               reuseDailyCryptoQuotes: Bool = false, includeHistoricalPlans: Bool = false,
                               historyNotBefore: Date? = nil,
                               includeClosedMarkets: Bool = false,
                               preview: ((InvestmentBook) -> Void)? = nil) async throws {
        guard loaded, !refreshing else { return }
        guard lastServerReadSucceeded else {
            throw InvestmentError.invalid("服务端暂不可用，继续使用本地行情与汇率；确认服务端缺失后才会查询行情接口。")
        }
        let scope = dataCacheScope
        let revision = ledgerRevision
        @MainActor @Sendable func checkRefresh() throws {
            try Task.checkCancellation()
            guard ledgerRevision == revision, scope == dataCacheScope else { throw CancellationError() }
        }
        refreshing = true
        defer {
            refreshing = false
        }
        do {
            let now = Date.now
            let today = InvestmentBook.day(now)
            let closedDay = InvestmentBook.addDays(-1, to: today)
            let snapshotRefresh = fullSnapshotHistory != nil
            var snapshotRequests: InvestmentSnapshotQuoteRequests?
            if let fullSnapshotHistory {
                var source = book
                if let dirty = serverState?.dirtyFrom.flatMap(records.day.date(from:)) {
                    source.invalidateDailySnapshots(from: dirty)
                }
                let valuationSource = source
                let worker = Task.detached(priority: .utility) {
                    valuationSource.historicalMarketDataRequests(through: closedDay,
                        fullHistory: fullSnapshotHistory, includePlans: includeHistoricalPlans, notBefore: historyNotBefore,
                        closedMarketsAt: includeClosedMarkets ? now : nil)
                }
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
            let sourceBook = book
            let diskCache = self.diskCache
            let marketCache = try await HakoExecutionDiagnostics.measure("读取并索引本地行情缓存", success: {
                "读取 1 份缓存；\($0.historyCount) 个查询区间、\($0.quoteCount) 条报价。后续标的和汇率共用此次读取。"
            }) { try await diskCache.marketReadSnapshot(scope: scope) }
            try checkRefresh()
            var cachedCryptoQuotes: [UUID: InvestmentQuote] = [:]
            if reuseDailyCryptoQuotes {
                cachedCryptoQuotes = try HakoExecutionDiagnostics.measure("检查加密货币当日报价缓存", success: {
                    "已复用 \($0.count) 个币种的当日报价。"
                }) {
                    var found: [UUID: InvestmentQuote] = [:]
                    for asset in ids.union(publicIDs).compactMap({ sourceBook.asset($0) }) where asset.kind == .crypto {
                        if let quote = marketCache.cachedCryptoSpotQuote(asset: asset, on: today,
                                                                         observations: sourceBook.quotes[asset.id] ?? []) {
                            try checkRefresh()
                            found[asset.id] = quote
                            HakoExecutionDiagnostics.record("复用加密货币报价 · " + asset.displayCode,
                                detail: "使用当天已获取的缓存报价。" + InvestmentQuoteProvider.quoteSummary([quote]))
                        }
                    }
                    return found
                }
            }
            let reusedCryptoQuotes = cachedCryptoQuotes
            let assets = ids.compactMap({ sourceBook.assets[$0] }).sorted(by: { $0.code < $1.code }).filter { asset in
                !publicQuotesOnly && (asset.usesEastmoneyMarketData || asset.usesUSEquityClose || !keys.isEmpty) && !asset.kind.isManual && (!asset.isHongKongEquity || asset.isStockConnect) &&
                    (!snapshotRefresh || asset.kind != .crypto) && reusedCryptoQuotes[asset.id] == nil
            }
            let assetRequests = snapshotRequests?.assets
            @MainActor @Sendable func readAssets() async throws -> [(UUID, [InvestmentQuote], [String])] {
                return try await InvestmentQuoteBatch.map(assets, channel: {
                    $0.usesEastmoneyMarketData ? "eastmoney" : "twelveData"
                }) { asset in
                    try checkRefresh()
                    var quotes: [InvestmentQuote] = []
                    var errors: [String] = []
                    let key = InvestmentDiskCache.historyKey(asset)
                    let saved = marketCache.marketQuotes(key: key)
                    let existing = sourceBook.quotes[asset.id] ?? []
                    let known = Set(existing.filter { $0.price > 0 && $0.isDailyClose != false }.map(\.day))
                    quotes = saved.filter { !known.contains($0.day) }
                    var observations = InvestmentBook.merge(saved, existing)
                    var checkedWindows: [ClosedRange<Date>] = []
                    var requestedWindows = 0
                    // Account history starts at this asset's first trade. Watch-only assets need a recent quote.
                    let requested = assetRequests?[asset.id] ?? [sourceBook.automaticQuoteWindow(for: asset.id, through: today)]
                    for range in requested {
                        let requests = HakoExecutionDiagnostics.measure("行情缓存缺口 · " + asset.displayCode, success: {
                            "发现 \($0.count) 个缺口；没有缺口时不调用行情接口。"
                        }) {
                            marketCache.missingWindows(key: key, start: range.lowerBound, end: range.upperBound,
                                today: today, observations: observations, additionalCoverage: checkedWindows,
                                requiredClose: includeClosedMarkets ? asset.lastClosedMarketDay(at: now) : nil)
                        }
                        for request in InvestmentHistoryRange.quoteWindows(for: requests) {
                            try checkRefresh()
                            do {
                                let result: [InvestmentQuote]
                                do {
                                    requestedWindows += 1
                                    result = try await HakoExecutionDiagnostics.measure("读取行情 · " + asset.displayCode,
                                        success: InvestmentQuoteProvider.quoteSummary) {
                                        try await MarketAPIRequestContext.$reason.withValue(snapshotRefresh ? "历史资产快照补数" : "持仓与关注行情刷新") {
                                            try await provider.history(asset: asset, start: request.lowerBound, through: request.upperBound,
                                                cached: nil, keys: keys)
                                        }
                                    }
                                } catch InvestmentError.noMarketData(_) { result = [] }
                                try checkRefresh()
                                // Persist downloaded data before attempting any server write.
                                try await diskCache.saveHistory(scope: scope, asset: asset, start: request.lowerBound,
                                    end: request.upperBound, today: today, quotes: result)
                                quotes = InvestmentBook.merge(quotes, result)
                                observations = InvestmentBook.merge(observations, result)
                                checkedWindows.append(request)
                            } catch {
                                try checkRefresh()
                                if !publicIDs.contains(asset.id) { errors.append(asset.displayCode + "（" + error.localizedDescription + "）") }
                            }
                        }
                    }
                    try checkRefresh()
                    HakoExecutionDiagnostics.record("行情缓存结果 · " + asset.displayCode,
                        detail: "本地报价 \(saved.count) 条；请求行情区间 \(requestedWindows) 个。0 个表示未调用行情接口。")
                    return (asset.id, quotes, errors)
                }
            }
            let publicAssets = publicIDs.compactMap { sourceBook.asset($0) }
            let missingSpotAssets = publicAssets.filter { reusedCryptoQuotes[$0.id] == nil }
            @MainActor @Sendable func readSpots() async throws -> [(UUID, InvestmentQuote?, String?)] {
                try checkRefresh()
                guard !missingSpotAssets.isEmpty else { return [] }
                return try await InvestmentQuoteBatch.map(missingSpotAssets) { token in
                    try checkRefresh()
                    do {
                        let quote = try await HakoExecutionDiagnostics.measure("读取现货美元报价 · " + token.code,
                            success: { InvestmentQuoteProvider.quoteSummary([$0]) }) {
                            try await provider.publicSpotUSDQuote(for: token)
                        }
                        try checkRefresh()
                        try await diskCache.saveCryptoSpotQuote(scope: scope, asset: token, quote: quote, on: today)
                        return (token.id, Optional(quote), Optional<String>.none)
                    } catch {
                        try checkRefresh()
                        return (token.id, Optional<InvestmentQuote>.none, Optional(token.code + "/USD（现货报价未更新）"))
                    }
                }
            }
            @MainActor @Sendable func readCrypto() async throws -> [UUID: [InvestmentQuote]] {
                guard refreshPublicHistory else { return [:] }
                try checkRefresh()
                let history = try await self.cryptoHistory(through: closedDay, provider: provider, missing: assetRequests)
                try checkRefresh()
                return history
            }
            let rateCurrenciesToCheck = Set(snapshotRequests?.rates.keys.map { $0 } ?? Array(currencies))
            let rateRequests = snapshotRequests?.rates
            @MainActor @Sendable func readRates() async throws -> [(InvestmentCurrency, [InvestmentQuote], [String])] {
                return try await InvestmentQuoteBatch.map(rateCurrenciesToCheck.sorted(by: { $0.rawValue < $1.rawValue })) { currency in
                    try checkRefresh()
                    var quotes: [InvestmentQuote] = []
                    var errors: [String] = []
                    let key = InvestmentDiskCache.rateKey(currency)
                    let saved = marketCache.marketQuotes(key: key)
                    let existing = sourceBook.fx[currency] ?? []
                    let known = Set(existing.filter { $0.price > 0 && $0.isDailyClose == true }.map(\.day))
                    quotes = saved.filter { !known.contains($0.day) }
                    var observations = InvestmentBook.mergeExchangeRates(existing, saved)
                    var checkedWindows: [ClosedRange<Date>] = []
                    for range in rateRequests?[currency] ?? [start...today] {
                        let first = InvestmentBook.weekdayMarketDate(on: range.lowerBound)
                        let last = InvestmentBook.weekdayMarketDate(on: range.upperBound)
                        let missing = HakoExecutionDiagnostics.measure("行情缓存缺口 · " + currency.rawValue + "/CNY", success: {
                            "发现 \($0.count) 个缺口；没有缺口时不调用汇率接口。"
                        }) {
                            marketCache.missingWindows(key: key, start: first, end: last, today: today,
                                observations: observations, additionalCoverage: checkedWindows)
                        }
                        for window in InvestmentHistoryRange.forexQuoteWindows(for: missing) {
                            try checkRefresh()
                            do {
                                let values = try await HakoExecutionDiagnostics.measure("读取汇率 · 欧洲央行 · " + currency.rawValue + "/CNY",
                                    success: InvestmentQuoteProvider.quoteSummary) {
                                    try await MarketAPIRequestContext.$reason.withValue("历史汇率补数") {
                                        try await provider.ecbRates(for: [currency], start: window.lowerBound, end: window.upperBound)[currency] ?? []
                                    }
                                }
                                try checkRefresh()
                                try await diskCache.saveMarketHistory(scope: scope, key: key, start: window.lowerBound,
                                    end: window.upperBound, today: today, quotes: values)
                                let finalDays = Set(observations.filter { $0.price > 0 && $0.isDailyClose == true }.map(\.day))
                                let added = values.filter { !finalDays.contains($0.day) }
                                quotes = InvestmentBook.mergeExchangeRates(quotes, added)
                                observations = InvestmentBook.mergeExchangeRates(observations, values)
                                checkedWindows.append(window)
                            } catch {
                                try checkRefresh()
                                errors.append(currency.rawValue + "/CNY（" + error.localizedDescription + "）")
                            }
                        }
                    }
                    try checkRefresh()
                    return (currency, quotes, errors)
                }
            }
            let (assetResults, spotResults, cryptoResults, rateResults) = try await HakoExecutionDiagnostics.measureGroup(
                "准备行情与汇率", branches: 4, detail: "标的行情、现货报价、加密历史行情和汇率并行准备；各渠道独立限制并发，分支耗时不相加。") {
                async let assetQuery: [(UUID, [InvestmentQuote], [String])] = HakoExecutionDiagnostics.parallel.withValue("标的行情") {
                    try await HakoExecutionDiagnostics.measure("准备标的行情", success: {
                        "已准备 \($0.count) 个标的；\($0.reduce(0) { $0 + $1.1.count }) 条报价。"
                    }) { try await readAssets() }
                }
                async let spotQuery: [(UUID, InvestmentQuote?, String?)] = HakoExecutionDiagnostics.parallel.withValue("现货报价") {
                    try await HakoExecutionDiagnostics.measure("准备现货报价", success: {
                        "新增 \($0.compactMap { $0.1 }.count) 个币种报价；其余使用当日缓存或暂未更新。"
                    }) { try await readSpots() }
                }
                async let cryptoQuery: [UUID: [InvestmentQuote]] = HakoExecutionDiagnostics.parallel.withValue("加密历史行情") {
                    try await HakoExecutionDiagnostics.measure("补齐加密货币历史行情", success: {
                        "已准备 \($0.values.reduce(0) { $0 + $1.count }) 条历史报价。"
                    }) { try await readCrypto() }
                }
                async let rateQuery: [(InvestmentCurrency, [InvestmentQuote], [String])] = HakoExecutionDiagnostics.parallel.withValue("外币汇率") {
                    try await HakoExecutionDiagnostics.measure("准备外币汇率", success: {
                        "已准备 \($0.count) 个币种；\($0.reduce(0) { $0 + $1.1.count }) 条汇率。"
                    }) { try await readRates() }
                }
                return try await (assetQuery, spotQuery, cryptoQuery, rateQuery)
            }
            try checkRefresh()
            var prices: [UUID: [InvestmentQuote]] = [:]
            var rates: [InvestmentCurrency: [InvestmentQuote]] = [:]
            var failures: [String] = []
            for (id, quotes, errors) in assetResults {
                prices[id] = quotes
                failures.append(contentsOf: errors)
            }
            for (id, quote) in reusedCryptoQuotes { prices[id, default: []].append(quote) }
            for (id, quote, failure) in spotResults {
                if let quote { prices[id, default: []].append(quote) }
                if let failure, prices[id]?.last?.day != today, sourceBook.quote(id)?.day != today { failures.append(failure) }
            }
            for (id, quotes) in cryptoResults { prices[id, default: []].append(contentsOf: quotes) }
            for (currency, quotes, errors) in rateResults {
                rates[currency] = quotes
                failures.append(contentsOf: errors)
            }
            try checkRefresh()
            guard publicQuotesOnly || self.keys() == keys else { return }
            let apply: (inout InvestmentBook) -> Void = { draft in
                HakoExecutionDiagnostics.measure("合并行情与汇率") {
                    for (id, values) in prices { draft.addQuotes(values, assetID: id) }
                    for (currency, values) in rates { draft.addExchangeRates(values, for: currency) }
                }
                if !snapshotRefresh {
                    let priorRuns = draft.planRuns
                    _ = HakoExecutionDiagnostics.measure("生成到期定投记录", success: { $0.message }) {
                        draft.runPlans(through: closedDay)
                        return draft.planReport(since: priorRuns)
                    }
                }
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
                try await publish(try await restoringMarketQuotes(in: book, scope: scope), context: authentication.requestContext)
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
        let histories = try await InvestmentQuoteBatch.map(requests) { request in
            let (asset, range) = request
            try Task.checkCancellation()
            let (start, end) = (range.lowerBound, range.upperBound)
            var quotes: [InvestmentQuote] = []
            if asset.kind == .crypto {
                let prices = try? await HakoExecutionDiagnostics.measure("读取历史行情 · Binance · " + asset.code,
                    success: InvestmentQuoteProvider.quoteSummary) {
                    try await provider.binanceSpotDailyQuotes(for: asset.code, from: start, through: end)
                }
                try Task.checkCancellation()
                if let prices, !prices.isEmpty {
                    quotes = prices
                }
            }
            try Task.checkCancellation()
            return (asset.id, quotes)
        }
        var result: [UUID: [InvestmentQuote]] = [:]
        for (id, quotes) in histories { result[id, default: []].append(contentsOf: quotes) }
        return result
    }
}
