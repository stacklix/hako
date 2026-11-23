import Foundation
import Combine
import CryptoKit

@MainActor final class WorkshopStore: ObservableObject {
    let authentication: any AuthenticatedServerAccess
    private var cloudSockets: [String: WorkshopRequestSocket] = [:]
    private var directSockets: [String: WorkshopRequestSocket] = [:]
    @Published private var localEndpoints: [String: LocalNetworkEndpoint] = [:]
    private var localCandidates: [String: [LocalNetworkEndpoint]] = [:]
    var localEndpoint: LocalNetworkEndpoint? { localEndpoint(for: selectedAgentID) }
    func localEndpoint(for agentID: String) -> LocalNetworkEndpoint? { localEndpoints[agentID] }
    var networkNamespace: String { authentication.serverURL + "\n" + authentication.username }
    let routeChanges = PassthroughSubject<Void, Never>()
    private var networkCheck = UUID()
    private var transportRevision = UUID()
    private var connectionPersistent = false
    private var subscription: AnyCancellable?
    private var context = ""
    private var preferences = WorkshopPreferences()
    private var cachedCatalogs: [String: WorkshopCachedCatalog] = [:]
    private var savedListSnapshot: WorkshopListSnapshot?
    private var savedPreferences: WorkshopPreferences?
    private let quotaCache = WorkshopQuotaCache()
    @Published private(set) var agents: [WorkshopAgent] = []
    @Published private(set) var applications: [WorkshopApplication] = []
    @Published private(set) var sessions: [WorkshopSession] = []
    @Published private(set) var loading = false
    @Published private(set) var loadingMore = false
    @Published private(set) var showingArchived = false
    @Published private(set) var archivingSessionID: String?
    @Published var error: String?
    @Published var selectedAgentID = ""
    @Published var selectedApplicationID = ""
    @Published private(set) var cachedAt: Date?
    @Published private var readState = WorkshopReadState()
    @Published private var localSessions = WorkshopLocalSessions()
    @Published private var draftRevision = 0
    @Published private(set) var systemPrompt = WorkshopSystemPrompt.defaultText
    @Published private(set) var systemPromptLoadError: String?
    @Published private(set) var connections: [String: WorkshopConnectionState] = [:]
    private var cursor: String?
    private var catalogRevision = UUID()
    private var refreshing = false
    private var catalogChecks: [String: Date] = [:]
    private var sessionUpdates = WorkshopSessionUpdates()
    private var activityChecks: [String: ContinuousClock.Instant] = [:]
    private let transcriptDisk = WorkshopTranscriptDisk()
    private let stateDisk = WorkshopPersistence()
    private var queuedSends: [WorkshopQueuedSend] = []
    private let draftWriter = WorkshopDraftWriter()
    private var draftCache: [URL: WorkshopComposerDraft] = [:]
    private var diagnosticUpload: Task<Void, Never>?
    private var computersLoaded = false
    private var computerDiscoveryID = UUID()
    private var artifactCache: [String: (Data, String)] = [:]

    init(authentication: (any AuthenticatedServerAccess)? = nil) {
        let authentication = authentication ?? AuthenticatedServerService.shared
        self.authentication = authentication
        subscription = authentication.changes.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.prepareContext() }
        }
        prepareContext()
    }

    // Authorization fences in-flight work; neither it nor the route identifies disk data.
    var scope: String { authentication.requestContext }
    var authenticated: Bool { !localEndpoints.isEmpty || authentication.authenticated && !authentication.logoutPending }
    var transportLabel: String { localEndpoint.map { "局域网直连 · " + $0.address } ?? "服务器转发" }
    func commandContext(for agentID: String) -> String {
        scope + "\n" + (localEndpoint(for: agentID)?.address ?? "server")
    }

    func beginVisit() {
        computerDiscoveryID = UUID()
        computersLoaded = false
    }

    func loadComputers() async {
        guard !computersLoaded, authentication.authenticated, !authentication.logoutPending else { return }
        computersLoaded = true
        let ticket = scope
        let visit = computerDiscoveryID
        do {
            let computers = try await cloudComputers()
            guard !Task.isCancelled, ticket == scope, visit == computerDiscoveryID else { return }
            try stateDisk.write(computers, to: computerCatalogFile)
            agents = computers
            if selectedAgent == nil {
                selectedAgentID = ""
                showCachedCatalog()
            }
            await prepareNetwork()
        } catch is CancellationError {
            if ticket == scope, visit == computerDiscoveryID { computersLoaded = false }
        } catch {
            if ticket == scope, visit == computerDiscoveryID {
                self.error = "无法读取执行电脑列表：" + error.localizedDescription
            }
        }
    }

    private func cloudComputers() async throws -> [WorkshopAgent] {
        let ticket = scope
        let catalog = try await HakoAgents.list(refresh: true)
        let computers = catalog.filter(\.supportsWorkshop).map { agent in
            let service = agent.modules?.workshop
            return WorkshopAgent(id: agent.id, name: agent.name, online: agent.online, protocolVersion: service?.version ?? 0,
                lan: .init(addresses: service?.lan?.addresses ?? [], port: service?.lan?.port ?? 0))
        }
        guard ticket == scope else { throw CancellationError() }
        return computers
    }

    private func configuredLocalEndpoints() async -> [String: [LocalNetworkEndpoint]] {
        let network = LocalNetworkService.shared
        await network.refresh()
        guard !Task.isCancelled, network.isLocal else { return [:] }
        return Dictionary(uniqueKeysWithValues: agents.compactMap { agent in
            let endpoints = WorkshopNetworkConfiguration.endpoints(addresses: agent.lan.addresses, port: agent.lan.port)
            return endpoints.isEmpty ? nil : (agent.id, endpoints)
        })
    }

    func prepareNetwork() async {
        let check = UUID(); networkCheck = check
        let ticket = scope
        let candidates = await configuredLocalEndpoints()
        guard !Task.isCancelled, ticket == scope, check == networkCheck, candidates != localCandidates else { return }
        let endpoints = candidates.compactMapValues(\.first)
        cloudSockets.values.forEach { $0.close() }; cloudSockets.removeAll()
        directSockets.values.forEach { $0.close() }; directSockets.removeAll()
        transportRevision = UUID()
        connections.removeAll()
        catalogRevision = UUID()
        refreshing = false
        loading = false
        localEndpoints = endpoints
        localCandidates = candidates
        for (agentID, endpoint) in endpoints {
            let addresses = candidates[agentID] ?? [endpoint]
            let direct = WorkshopRequestSocket(context: { "local:" + agentID + ":" + endpoint.address }, open: {
                try await WorkshopLocalSocket.open(addresses, computerID: agentID)
            })
            direct.onDisconnect = { [weak self] in self?.connections[agentID] = .reconnecting }
            direct.onDiagnostic = { [weak self] in self?.recordDiagnostic($0, detail: $1) }
            direct.onFailure = { HakoLog.record(.codeWorkshop, "工坊局域网共享连接中断", detail: WorkshopSocketDiagnostics.error($0)) }
            direct.setPersistent(connectionPersistent)
            directSockets[agentID] = direct
        }
        prepareContext()
        routeChanges.send()
    }

    private func requests(for agentID: String) -> WorkshopRequestSocket {
        if let direct = directSockets[agentID] { return direct }
        if let existing = cloudSockets[agentID] { return existing }
        let authentication = self.authentication
        let socket = WorkshopRequestSocket(context: { authentication.requestContext }, open: {
            let ticket = authentication.requestContext
            let ready = try await HakoAgents.open("workshop", agentID: agentID)
            guard ticket == authentication.requestContext else { throw CancellationError() }
            return try await authentication.openWebSocket(ready.path, logSource: .codeWorkshop)
        }, diagnostic: { event, detail in
            HakoLog.record(.codeWorkshop, event.contains("failed") || event == "disconnected" ? .warning : .info,
                           "会话连接：\(event)", detail: detail)
        })
        socket.onDisconnect = { [weak self] in self?.connections[agentID] = .reconnecting }
        socket.onDiagnostic = { [weak self] in self?.recordDiagnostic($0, detail: $1) }
        socket.onFailure = { HakoLog.record(.codeWorkshop, "工坊共享连接中断", detail: WorkshopSocketDiagnostics.error($0)) }
        socket.setPersistent(connectionPersistent)
        cloudSockets[agentID] = socket
        return socket
    }

    func recordDiagnostic(_ event: String, detail: String) {
        let file = cacheFile.deletingPathExtension().appendingPathExtension("diagnostics.json")
        Task { do { try await WorkshopDiagnosticOutbox.shared.append(event, detail: detail, file: file) }
            catch { HakoLog.record(.codeWorkshop, .warning, "连接诊断无法保存", detail: WorkshopSocketDiagnostics.error(error)) } }
    }

    private func uploadDiagnostics(to agent: WorkshopAgent) {
        guard diagnosticUpload == nil else { return }
        let file = cacheFile.deletingPathExtension().appendingPathExtension("diagnostics.json")
        let ticket = scope
        diagnosticUpload = Task { [weak self] in
            defer { self?.diagnosticUpload = nil }
            // Bounded low-priority batches never delay conversation requests.
            for _ in 0..<4 {
                guard let self, !Task.isCancelled, self.scope == ticket else { return }
                let batch = await WorkshopDiagnosticOutbox.shared.batch(file: file)
                guard self.scope == ticket, !Task.isCancelled else { return }
                guard !batch.isEmpty else { return }
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                do {
                    let records = try JSONSerialization.jsonObject(with: encoder.encode(batch))
                    _ = try await self.requests(for: agent.id).send("diagnostics.append", computerID: agent.id, params: ["records": records])
                    guard self.scope == ticket else { return }
                    try await WorkshopDiagnosticOutbox.shared.acknowledge(Set(batch.map(\.id)), file: file)
                } catch { return } // Retain the spool; retry after the next successful read.
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func setConnectionForeground(_ foreground: Bool) {
        connectionPersistent = foreground
        cloudSockets.values.forEach { $0.setPersistent(foreground) }; directSockets.values.forEach { $0.setPersistent(foreground) }
    }

    private func connectionInterrupted() {
        for (id, state) in connections where state != .disconnected { connections[id] = .reconnecting }
    }

    private func verifyNetworkRoute() async throws {
        let expected = localCandidates
        let current = await configuredLocalEndpoints()
        try Task.checkCancellation()
        guard current == expected else {
            await prepareNetwork()
            throw CancellationError()
        }
    }
    var selectedAgent: WorkshopAgent? { agents.first { $0.id == selectedAgentID } }
    var selectedApplication: WorkshopApplication? { applications.first { $0.id == selectedApplicationID } }
    var orderedApplications: [WorkshopApplication] {
        // Browsing archived conversations must not change the active project order.
        let active = showingArchived ? (cachedCatalogs[catalogKey(selectedAgentID, archived: false)]?.catalog.sessions ?? []) : sessions
        let visible = localSessions.merging(active, agentId: selectedAgentID, applications: applications, archived: false)
        return WorkshopCatalog.orderedApplications(applications, sessions: visible, order: preferences.order)
    }
    var visibleSessions: [WorkshopSession] {
        sessionListItems(at: .now).map(\.session)
    }

    func sessionListItems(at date: Date) -> [WorkshopSessionListItem] {
        let visible = localSessions.merging(sessions, agentId: selectedAgentID, applications: applications, archived: showingArchived)
            .filter { $0.applicationId == selectedApplicationID }
        return WorkshopCatalog.listItems(visible, hasDraft: { self.hasDraft($0) }, isUnread: { self.isUnread($0, at: date) })
    }
    var hasMore: Bool { cursor != nil }

    private func catalogKey(_ agentID: String, archived: Bool) -> String {
        archived ? agentID + ":archived" : agentID
    }

    private var cacheFile: URL {
        let account = WorkshopCacheIdentity.account(serverURL: authentication.serverURL, username: authentication.username)
        let digest = SHA256.hash(data: Data(account.utf8)).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodeWorkshop", isDirectory: true).appendingPathComponent(digest + ".json")
    }

    private var listCacheFile: URL {
        cacheFile.deletingLastPathComponent().appendingPathComponent(cacheFile.deletingPathExtension().lastPathComponent + "-lists.json")
    }

    private var readStateFile: URL { cacheFile.deletingPathExtension().appendingPathExtension("read.json") }
    private var computerCatalogFile: URL { cacheFile.deletingPathExtension().appendingPathExtension("workshop-computers.json") }

    private func quotaCacheFile(for agentID: String) -> URL {
        let digest = SHA256.hash(data: Data(agentID.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheFile.deletingPathExtension().appendingPathExtension("quota")
            .appendingPathComponent(digest + ".json")
    }

    func cachedQuota(for agentID: String, at now: Date = .now) -> WorkshopQuotaCacheEntry? {
        quotaCache.cached(at: quotaCacheFile(for: agentID), now: now)
    }

    func loadCachedQuota(for agentID: String) async -> WorkshopQuotaCacheEntry? {
        let file = quotaCacheFile(for: agentID), disk = stateDisk
        return await quotaCache.load(file) {
            try? await disk.readAsync(WorkshopQuotaCacheEntry.self, from: file)
        }
    }

    func cacheQuota(_ entry: WorkshopQuotaCacheEntry, for agentID: String) {
        // Quota is disposable metadata; a disk failure must not affect the live result or conversation.
        let file = quotaCacheFile(for: agentID)
        quotaCache.store(entry, at: file)
        stateDisk.schedule(entry, to: file) { _ in }
    }

    func clearCachedQuota(for agentID: String) async throws {
        let file = quotaCacheFile(for: agentID)
        quotaCache.remove(at: file)
        try await stateDisk.remove(file)
    }

    var settingsAccount: String {
        WorkshopCacheIdentity.account(serverURL: authentication.serverURL, username: authentication.username)
    }
    private var systemPromptFile: URL { cacheFile.deletingPathExtension().appendingPathExtension("instructions.txt") }

    func saveSystemPrompt(_ text: String) throws {
        guard context == scope else { throw CancellationError() }
        guard WorkshopSystemPrompt.valid(text) else { throw HakoError(message: "系统提示词最多 4,000 个字符，且不能包含空字符。") }
        var file = systemPromptFile
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try Data(text.utf8).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try Data(text.utf8).write(to: file, options: .atomic)
        #endif
        var flags = URLResourceValues(); flags.isExcludedFromBackup = false
        try file.setResourceValues(flags)
        systemPrompt = text
        systemPromptLoadError = nil
    }

    func isUnread(_ session: WorkshopSession, at date: Date) -> Bool {
        readState.isUnread(session, agentId: selectedAgentID, now: date)
    }

    func markRead(threadId: String, completionId: String, agentId: String) {
        guard context == scope else { return }
        var updated = readState
        guard updated.markRead(threadId: threadId, completionId: completionId, agentId: agentId) else { return }
        readState = updated
        scheduleState(updated, to: readStateFile)
    }

    func observeSession(threadId: String, operationId: String?, state: String, completionId: String?,
                        agent: WorkshopAgent, scope ticket: String) {
        guard context == ticket, scope == ticket else { return }
        let selected = selectedAgentID == agent.id
        let catalogs = cachedCatalogs.filter { $0.key == agent.id || $0.key == agent.id + ":archived" }
        let candidates = selected ? localSessions.merging(sessions, agentId: agent.id, applications: applications, archived: showingArchived) : []
        guard let previous = candidates.first(where: { $0.id == threadId }) ?? catalogs.values
            .flatMap({ $0.catalog.sessions }).first(where: { $0.id == threadId }),
              previous.operationId == operationId || previous.operationId == nil else { return }
        let updated = WorkshopSession(id: previous.id, title: previous.title, applicationId: previous.applicationId,
            cwd: previous.cwd, preview: previous.preview, updatedAt: previous.updatedAt, state: state,
            operationId: operationId, completionId: state == "completed" ? completionId : nil, lastSentAt: previous.lastSentAt,
            access: previous.access)
        let terminal = ["completed", "failed", "interrupted", "cancelled", "unknown", "paused"].contains(state)
        if terminal {
            // Also settle the durable receipt, so reopening the app cannot
            // restore a pending overlay for an operation already verified done.
            var changed = false
            for index in preferences.receipts.indices where preferences.receipts[index].agentId == agent.id && preferences.receipts[index].id == operationId {
                if preferences.receipts[index].state != state {
                    preferences.receipts[index].state = state; changed = true
                }
            }
            if changed { try? persist(background: true) }
            localSessions.settle(threadId: threadId, operationId: operationId, agentId: agent.id)
        }
        let previousRaw = selected ? sessions.first(where: { $0.id == threadId }) : catalogs.values
            .flatMap({ $0.catalog.sessions }).first(where: { $0.id == threadId })
        guard previousRaw != updated else { return }
        sessionUpdates.record(updated, agentId: agent.id)
        if selected {
            if let index = sessions.firstIndex(where: { $0.id == threadId }) { sessions[index] = updated }
            else { sessions.append(updated); sessions = WorkshopCatalog.ordered(sessions) }
        }
        for (key, cached) in catalogs {
            let values = cached.catalog.sessions.map { $0.id == threadId ? updated : $0 }
            cachedCatalogs[key] = WorkshopCachedCatalog(catalog: WorkshopCatalog(applications: cached.catalog.applications,
                sessions: values, nextCursor: cached.catalog.nextCursor), savedAt: cached.savedAt)
        }
        try? saveLists(background: true)
    }

    private func transcriptFile(_ key: WorkshopTranscriptKey) -> URL {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let identity = (try? encoder.encode(key)) ?? Data()
        let hash = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        return cacheFile.deletingLastPathComponent()
            .appendingPathComponent("messages-" + cacheFile.deletingPathExtension().lastPathComponent, isDirectory: true)
            .appendingPathComponent(hash + ".json")
    }

    func cachedTranscript(_ key: WorkshopTranscriptKey) async -> WorkshopTranscript? {
        guard context == scope else { return nil }
        let ticket = scope
        let snapshot = await transcriptDisk.read(transcriptFile(key), key: key)
        return ticket == scope ? snapshot : nil
    }

    func saveTranscript(_ snapshot: WorkshopTranscript, scope ticket: String) {
        guard context == ticket, scope == ticket else { return }
        transcriptDisk.write(snapshot, to: transcriptFile(snapshot.key))
    }

    private func draftFile(agent: WorkshopAgent, application: WorkshopApplication, sessionId: String) -> URL {
        let key = WorkshopTranscriptKey(agentId: agent.id, applicationId: application.id, threadId: sessionId)
        return transcriptFile(key).deletingPathExtension().appendingPathExtension("draft.json")
    }

    func composerDraft(agent: WorkshopAgent, application: WorkshopApplication, sessionId: String) throws -> WorkshopComposerDraft? {
        guard context == scope else { throw CancellationError() }
        let file = draftFile(agent: agent, application: application, sessionId: sessionId)
        if let cached = draftCache[file] { return cached.isEmpty ? nil : cached }
        let saved = try WorkshopDraftDisk.read(file)
        draftCache[file] = saved ?? WorkshopComposerDraft(input: WorkshopDraftInput(text: "", imageIds: []))
        return saved
    }

    func hasDraft(_ session: WorkshopSession) -> Bool {
        _ = draftRevision
        guard context == scope, let agent = selectedAgent,
              let application = applications.first(where: { $0.id == session.applicationId }) else { return false }
        return (try? composerDraft(agent: agent, application: application, sessionId: session.id))?.hasUnsentInput == true
    }

    func saveComposerDraft(_ draft: WorkshopComposerDraft, agent: WorkshopAgent, application: WorkshopApplication,
                           sessionId: String, previousSessionId: String, scope ticket: String,
                           onFailure: @escaping @MainActor (Error) -> Void) throws {
        guard context == ticket, scope == ticket else { throw CancellationError() }
        let file = draftFile(agent: agent, application: application, sessionId: sessionId)
        let previous = previousSessionId == sessionId ? nil : draftFile(agent: agent, application: application, sessionId: previousSessionId)
        let markerChanged = (draftCache[file]?.hasUnsentInput ?? false) != draft.hasUnsentInput
            || previous.map { draftCache[$0]?.hasUnsentInput == true } == true
        draftCache[file] = draft
        if let previous { draftCache[previous] = WorkshopComposerDraft(input: WorkshopDraftInput(text: "", imageIds: [])) }
        draftWriter.write(draft, to: file, removing: previous) { [weak self] result in
            if case .failure(let error) = result {
                Task { @MainActor [weak self] in
                    guard let self, self.scope == ticket else { return }
                    onFailure(error)
                }
            }
        }
        if markerChanged { draftRevision += 1 }
    }

    func flushComposerDrafts() async {
        await draftWriter.flush()
        await stateDisk.flush()
        await transcriptDisk.flush()
    }

    func recordQueuedActivity(_ queued: WorkshopQueuedSend, agent: WorkshopAgent, application: WorkshopApplication,
                              threadId: String?, title: String, scope ticket: String) {
        guard context == ticket, scope == ticket, let threadId else { return }
        let receipt = WorkshopReceipt(id: queued.operationId, agentId: agent.id, applicationId: application.id,
            originalThreadId: threadId, threadId: threadId, title: title, message: queued.message, createdAt: .now, state: "pending")
        sessionUpdates.remove(threadId: threadId, agentId: agent.id)
        localSessions.record(receipt, isNew: true, queued: true, queuedMessageId: queued.id)
    }

    func rejectQueuedActivity(_ queued: WorkshopQueuedSend, agent: WorkshopAgent, scope ticket: String) {
        guard context == ticket, scope == ticket else { return }
        localSessions.reject(operationId: queued.operationId, agentId: agent.id)
    }

    private func prepareContext() {
        guard context != scope else { return }
        context = scope
        refreshing = false
        savedPreferences = nil; savedListSnapshot = nil
        quotaCache.reset()
        sessionUpdates = WorkshopSessionUpdates()
        activityChecks.removeAll()
        catalogChecks.removeAll(); beginVisit()
        artifactCache.removeAll()
        connections.removeAll()
        localEndpoints = [:]; localCandidates = [:]
        directSockets.values.forEach { $0.close() }; directSockets.removeAll()
        cloudSockets.values.forEach { $0.close() }; cloudSockets.removeAll()
        preferences = (try? stateDisk.read(WorkshopPreferences.self, from: cacheFile)) ?? WorkshopPreferences()
        savedPreferences = preferences
        queuedSends = (try? stateDisk.read([WorkshopQueuedSend].self, from: queueFile)) ?? []
        localSessions = WorkshopLocalSessions()
        for receipt in preferences.receipts where receipt.state == "pending" { localSessions.record(receipt, isNew: true) }
        readState = (try? stateDisk.read(WorkshopReadState.self, from: readStateFile)) ?? WorkshopReadState()
        selectedAgentID = preferences.agentId
        selectedApplicationID = preferences.applicationId
        agents = []; applications = []; sessions = []; cursor = nil; error = nil; loading = false
        showingArchived = false; archivingSessionID = nil
        cachedCatalogs = [:]; cachedAt = nil
        systemPrompt = WorkshopSystemPrompt.defaultText
        systemPromptLoadError = nil
        if FileManager.default.fileExists(atPath: systemPromptFile.path) {
            do {
                let text = try String(contentsOf: systemPromptFile, encoding: .utf8)
                guard WorkshopSystemPrompt.valid(text) else { throw CocoaError(.coderReadCorrupt) }
                systemPrompt = text
            } catch { systemPromptLoadError = "无法读取已保存的系统提示词，请在代码工坊设置中检查后重新保存。" }
        }
        if let snapshot = try? stateDisk.read(WorkshopListSnapshot.self, from: listCacheFile) {
            savedListSnapshot = snapshot
            cachedCatalogs = snapshot.catalogs
            // A saved list is available immediately, but cannot establish live connectivity.
            agents = snapshot.agents.map { WorkshopAgent(id: $0.id, name: $0.name, online: false,
                protocolVersion: $0.protocolVersion, lan: $0.lan) }
            showCachedCatalog()
        }
        if let computers = try? stateDisk.read([WorkshopAgent].self, from: computerCatalogFile) {
            agents = computers.map { WorkshopAgent(id: $0.id, name: $0.name, online: false, protocolVersion: $0.protocolVersion, lan: $0.lan) }
            showCachedCatalog()
        }
    }

    private func showCachedCatalog(keepApplications: Bool = false) {
        let saved = cachedCatalogs[catalogKey(selectedAgentID, archived: showingArchived)]
        applications = saved?.catalog.applications ?? (keepApplications ? applications : [])
        sessions = saved?.catalog.sessions ?? []
        cursor = saved?.catalog.nextCursor
        cachedAt = saved?.savedAt
        if !applications.contains(where: { $0.id == selectedApplicationID }) {
            selectedApplicationID = orderedApplications.first?.id ?? ""
        }
    }

    private func saveLists(background: Bool = false) throws {
        let values = sessions.filter { UUID(uuidString: $0.id) != nil }
        let key = catalogKey(selectedAgentID, archived: showingArchived)
        let catalog = WorkshopCatalog(applications: applications, sessions: Array(values), nextCursor: cursor)
        if cachedCatalogs[key]?.catalog != catalog {
            let previous = cachedCatalogs[key]
            let savedAt = previous.map { catalog.hasSameListContent(as: $0.catalog) ? $0.savedAt : .now } ?? .now
            cachedCatalogs[key] = WorkshopCachedCatalog(catalog: catalog, savedAt: savedAt)
        }
        // A direct connection exposes only its own computer. Its inventory is not
        // evidence that cached catalogs for other computers should be deleted.
        let snapshot = WorkshopListSnapshot(agents: agents, catalogs: cachedCatalogs)
        guard savedListSnapshot.map({ !snapshot.hasSameListContent(as: $0) }) ?? true else { return }
        if background { scheduleState(snapshot, to: listCacheFile) }
        else { try stateDisk.write(snapshot, to: listCacheFile) }
        savedListSnapshot = snapshot
    }

    private func persist(background: Bool = false) throws {
        preferences.agentId = selectedAgentID
        preferences.applicationId = selectedApplicationID
        guard preferences != savedPreferences else { return }
        if background { scheduleState(preferences, to: cacheFile) }
        else { try stateDisk.write(preferences, to: cacheFile) }
        savedPreferences = preferences
    }

    private func scheduleState<Value: Encodable & Sendable>(_ value: Value, to file: URL) {
        let ticket = scope
        stateDisk.schedule(value, to: file) { [weak self] result in
            if case .failure = result {
                Task { @MainActor [weak self] in
                    guard let self, self.scope == ticket else { return }
                    self.savedPreferences = nil; self.savedListSnapshot = nil
                    self.error = "无法保存代码工坊状态，请检查设备存储空间。"
                }
            }
        }
    }

    func renameSession(_ threadID: String, agentID: String, title: String) {
        func renamed(_ value: WorkshopSession) -> WorkshopSession {
            guard value.id == threadID else { return value }
            return WorkshopSession(id: value.id, title: title, applicationId: value.applicationId, cwd: value.cwd,
                preview: value.preview, updatedAt: value.updatedAt, state: value.state,
                operationId: value.operationId, completionId: value.completionId, lastSentAt: value.lastSentAt, access: value.access)
        }
        if selectedAgentID == agentID { sessions = sessions.map(renamed) }
        for (key, value) in cachedCatalogs where key == agentID || key == agentID + ":archived" {
            cachedCatalogs[key] = WorkshopCachedCatalog(catalog: WorkshopCatalog(applications: value.catalog.applications,
                sessions: value.catalog.sessions.map(renamed), nextCursor: value.catalog.nextCursor), savedAt: value.savedAt)
        }
        try? saveLists(background: true)
    }

    func selectApplication(_ id: String) {
        selectedApplicationID = id
        do { try persist() } catch { self.error = "无法保存应用选择。" }
    }

    func selectArchiveMode(_ archived: Bool) async {
        guard archived != showingArchived, !loading, archivingSessionID == nil,
              !archived || selectedAgent?.supportsArchiving == true else { return }
        catalogRevision = UUID(); refreshing = false
        showingArchived = archived
        showCachedCatalog(keepApplications: true)
        await refresh()
    }

    func setArchived(_ threadId: String, archived: Bool, agent: WorkshopAgent) async -> Bool {
        guard authenticated, agent.online, agent.supportsArchiving, archivingSessionID == nil,
              UUID(uuidString: threadId) != nil else {
            error = "当前无法修改归档状态，请确认电脑在线且没有其他归档操作正在进行。"
            return false
        }
        let ticket = scope
        // A list read started before this mutation must not restore its stale rows.
        catalogRevision = UUID()
        refreshing = false; loading = false
        archivingSessionID = threadId; error = nil
        defer { if ticket == scope { archivingSessionID = nil } }
        do {
            let reply: WorkshopArchiveReply = try await call(agent, "thread.archive", ["threadId": threadId, "archived": archived])
            guard ticket == scope else { return false }
            guard reply.threadId == threadId, reply.archived == archived else {
                error = "归档结果与请求不一致，请刷新列表核对。"
                return false
            }
            localSessions.remove(threadId: threadId, agentId: agent.id)
            if selectedAgentID == agent.id {
                sessions.removeAll { $0.id == threadId }
                cachedCatalogs[catalogKey(agent.id, archived: archived)] = nil
                try? saveLists()
                archivingSessionID = nil
                await refresh()
            }
            return true
        } catch is CancellationError { return false }
        catch let failure as WorkshopFailure {
            if ticket == scope { error = failure.message }
            return false
        }
        catch {
            if ticket == scope { self.error = "\(archived ? "归档" : "取消归档")结果尚未确认，请刷新列表核对。\(error.localizedDescription)" }
            return false
        }
    }

    func selectAgent(_ id: String) async {
        guard id != selectedAgentID, agents.contains(where: { $0.id == id }) else { return }
        catalogRevision = UUID(); refreshing = false; loading = false
        selectedAgentID = id
        showingArchived = false
        showCachedCatalog()
        preferences.order = []; preferences.seenSessions = []
        do { try persist() } catch { self.error = "无法保存电脑选择。" }
        await refresh()
    }

    func restore() async {
        await prepareNetwork()
        if localEndpoint == nil { await authentication.restore() }
        prepareContext()
        await loadComputers()
        await refresh()
    }

    func loadMore() async {
        guard !loadingMore, hasMore else { return }
        let ticket = scope
        let agentID = selectedAgentID
        let applicationID = selectedApplicationID
        let archived = showingArchived
        loadingMore = true
        defer { loadingMore = false }
        func isCurrent() -> Bool {
            !Task.isCancelled && scope == ticket && selectedAgentID == agentID &&
                selectedApplicationID == applicationID && showingArchived == archived
        }
        // A user request waits for the current poll instead of being dropped.
        while refreshing {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard isCurrent() else { return }
        }
        guard isCurrent() else { return }
        guard selectedAgent?.online == true else {
            error = "电脑当前离线，联网后可加载更早的会话。"
            return
        }
        let existing = Set(visibleSessions.map(\.id))
        var visited = Set<String>()
        // Catalog pages span all projects. Continue until this project gains a
        // row, rather than completing an apparently empty load for another one.
        while isCurrent(), let next = cursor, visited.insert(next).inserted {
            await refresh(more: true)
            guard isCurrent(), error == nil, cursor != next else { return }
            if visibleSessions.contains(where: { !existing.contains($0.id) }) { return }
        }
    }

    func refresh(more: Bool = false, reconcile: Bool = true) async {
        let waitingScope = scope
        // An explicit refresh waits for an automatic read rather than vanishing.
        while reconcile && !more && refreshing {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard scope == waitingScope else { return }
        }
        await prepareNetwork()
        guard authenticated, !refreshing, !loadingMore || more, archivingSessionID == nil,
              !more || hasMore else { return }
        let ticket = scope
        let revision = catalogRevision
        let sessionCheckpoint = sessionUpdates.revision
        let archived = showingArchived
        refreshing = true
        if more || reconcile { loading = true }
        defer {
            if scope == ticket, revision == catalogRevision {
                refreshing = false
                if loading { loading = false }
            }
        }
        do {
            guard let agent = selectedAgent, (agent.online || localEndpoint(for: agent.id) != nil), agent.supported else { return }
            var params: [String: Any] = more ? cursor.map { ["cursor": $0] } ?? [:] : [:]
            if archived { params["archived"] = true }
            let previousSessions = sessions
            let refreshKey = catalogKey(agent.id, archived: archived)
            let reconcilePages = !more && (reconcile || (catalogChecks[refreshKey].map { Date.now.timeIntervalSince($0) >= 30 } ?? true))
            let previousCursor = cursor
            let page: WorkshopCatalog = try await call(agent, "applications.list", params)
            guard ticket == scope, revision == catalogRevision, selectedAgentID == agent.id, showingArchived == archived else { return }
            // Publish the newest page before slower reconciliation of older pages.
            if applications != page.applications { applications = page.applications }
            let initialSessions = WorkshopCatalog.merge(sessionUpdates.merging(page.sessions, agentId: agent.id, since: sessionCheckpoint), existing: previousSessions, more: true)
                .filter { session in applications.contains { $0.id == session.applicationId } }
            if !WorkshopCatalog.sameListContent(sessions, initialSessions) { sessions = initialSessions }
            if !archived { confirmSessions(page.sessions, agentId: agent.id) }
            if cachedAt != nil { cachedAt = nil }
            var freshSessions = page.sessions
            var nextCursor = page.nextCursor
            let loadedCount = previousSessions.filter { UUID(uuidString: $0.id) != nil }.count
            var visited = Set<String>()
            // Refresh all previously loaded pages so externally archived/restored
            // threads cannot survive in a stale merged catalog.
            while reconcilePages, freshSessions.count < loadedCount, let next = nextCursor, visited.insert(next).inserted {
                var nextParams: [String: Any] = ["cursor": next]
                if archived { nextParams["archived"] = true }
                let older: WorkshopCatalog = try await call(agent, "applications.list", nextParams)
                guard ticket == scope, revision == catalogRevision, selectedAgentID == agent.id, showingArchived == archived else { return }
                freshSessions += older.sessions
                nextCursor = older.nextCursor
                if nextCursor == next { break }
            }
            guard ticket == scope, revision == catalogRevision, selectedAgentID == agent.id, showingArchived == archived else { return }
            let finalSessions = WorkshopCatalog.merge(sessionUpdates.merging(freshSessions, agentId: agent.id, since: sessionCheckpoint), existing: previousSessions, more: more || !reconcilePages)
                .filter { session in applications.contains { $0.id == session.applicationId } }
            if !WorkshopCatalog.sameListContent(sessions, finalSessions) { sessions = finalSessions }
            if !archived { confirmSessions(freshSessions, agentId: agent.id) }
            cursor = !more && !reconcilePages && loadedCount > page.sessions.count ? previousCursor : nextCursor
            if reconcilePages { catalogChecks[refreshKey] = .now }
            if cachedAt != nil { cachedAt = nil }
            let newSessions = page.sessions.filter { !preferences.seenSessions.contains($0.id) }
            if !more && !archived {
                for session in newSessions.sorted(by: { $0.lastSentAt < $1.lastSentAt }) { promote(session.applicationId) }
            }
            if !newSessions.isEmpty { preferences.seenSessions = Array(Set(preferences.seenSessions + page.sessions.map(\.id))).sorted() }
            if !applications.contains(where: { $0.id == selectedApplicationID }) { selectedApplicationID = orderedApplications.first?.id ?? "" }
            try persist(background: true)
            try saveLists(background: true)
            if error != nil { error = nil }
            if !archived { await verifyLocalActivity(agent: agent, ticket: ticket, revision: revision) }
        } catch is CancellationError { }
        catch { if ticket == scope, revision == catalogRevision { self.error = error.localizedDescription } }
    }

    private func verifyLocalActivity(agent: WorkshopAgent, ticket: String, revision: UUID) async {
        struct Result: Decodable { let operation: WorkshopOperation; let followups: [WorkshopFollowupState] }
        let now = ContinuousClock.now
        let checks = localSessions.verifications(for: sessions, agentId: agent.id).filter {
            activityChecks[$0.operationId + ":\($0.revision)"].map { $0.duration(to: now) >= .seconds(30) } ?? true
        }.prefix(3)
        for check in checks {
            guard !Task.isCancelled, scope == ticket, catalogRevision == revision, selectedAgentID == agent.id else { return }
            activityChecks[check.operationId + ":\(check.revision)"] = now
            do {
                let result: Result = try await call(agent, "operation.read", ["operationId": check.operationId, "cursor": 0])
                guard !Task.isCancelled, scope == ticket, catalogRevision == revision, selectedAgentID == agent.id else { return }
                guard localSessions.verify(check, operation: result.operation, followups: result.followups,
                    pendingMessages: pendingQueue(operationId: check.operationId).map(\.id)) else { continue }
                // Resolve the old receipt without replacing a newer catalog
                // operation, its completion marker or its preview.
                var changed = false
                for index in preferences.receipts.indices where preferences.receipts[index].agentId == agent.id &&
                    preferences.receipts[index].id == check.operationId {
                    if preferences.receipts[index].state != result.operation.state {
                        preferences.receipts[index].state = result.operation.state; changed = true
                    }
                }
                if changed { try persist(background: true) }
            } catch is CancellationError { return }
            catch let failure as WorkshopFailure where failure.code == "codex_operation_missing" {
                guard !Task.isCancelled, scope == ticket, catalogRevision == revision, selectedAgentID == agent.id else { return }
                guard localSessions.verifyMissing(check, sessions: sessions, history: preferences.receipts,
                    pendingMessages: pendingQueue(operationId: check.operationId).map(\.id)) else { continue }
                // Keep the original input and receipt. Its result is unknown;
                // a later confirmed request owns the conversation's list state.
                for index in preferences.receipts.indices where preferences.receipts[index].agentId == agent.id &&
                    preferences.receipts[index].id == check.operationId {
                    preferences.receipts[index].state = "unknown"
                }
                try? persist(background: true)
                HakoLog.record(.codeWorkshop, "已解除旧请求的进行中状态", detail: "operationId=\(check.operationId); result=missing; newerRequest=verified")
            }
            catch { /* Keep unconfirmed activity visible and retry later. */ }
        }
    }

    private func confirmSessions(_ sessions: [WorkshopSession], agentId: String) {
        var confirmed = localSessions
        confirmed.confirm(sessions, agentId: agentId)
        if confirmed != localSessions { localSessions = confirmed }
        var changed = false
        for index in preferences.receipts.indices where preferences.receipts[index].agentId == agentId && preferences.receipts[index].state == "pending" {
            guard let session = sessions.first(where: { $0.operationId == preferences.receipts[index].id }),
                  ["completed", "failed", "interrupted", "cancelled"].contains(session.state) else { continue }
            preferences.receipts[index].state = session.state
            changed = true
        }
        if changed { try? persist(background: true) }
    }

    private func promote(_ applicationID: String) {
        preferences.order.removeAll { $0 == applicationID }
        preferences.order.insert(applicationID, at: 0)
    }

    func receipt(for session: WorkshopSession?, agent: WorkshopAgent) -> WorkshopReceipt? {
        guard let session else { return nil }
        return preferences.receipts.last { $0.agentId == agent.id && ($0.id == session.operationId || $0.threadId == session.id) }
    }

    func saveReceipt(_ receipt: WorkshopReceipt, background: Bool = false) throws {
        guard context == scope else { throw CancellationError() }
        guard preferences.receipts.first(where: { $0.id == receipt.id }) != receipt else { return }
        let previous = preferences
        let isNew = !preferences.receipts.contains { $0.id == receipt.id }
        if let index = preferences.receipts.firstIndex(where: { $0.id == receipt.id }) { preferences.receipts[index] = receipt }
        else {
            preferences.receipts.append(receipt)
            if preferences.receipts.count > 100 { preferences.receipts.removeFirst() }
            if receipt.originalThreadId == nil { promote(receipt.applicationId) }
        }
        do { try persist(background: background) }
        catch { preferences = previous; throw error }
        if isNew, let threadId = receipt.threadId {
            sessionUpdates.remove(threadId: threadId, agentId: receipt.agentId)
        }
        localSessions.record(receipt, isNew: isNew)
    }

    private var queueFile: URL { cacheFile.deletingPathExtension().appendingPathExtension("queue.json") }

    func pendingQueue(operationId: String) -> [WorkshopQueuedSend] {
        queuedSends.filter { $0.operationId == operationId }
    }

    func saveQueuedSend(_ send: WorkshopQueuedSend?, removing id: String? = nil, background: Bool = false) throws {
        guard context == scope else { throw CancellationError() }
        var values = queuedSends
        if send == nil, let id, !values.contains(where: { $0.id == id }) { return }
        if let id { values.removeAll { $0.id == id } }
        if let send { values.removeAll { $0.id == send.id }; values.append(send) }
        guard values != queuedSends else { return }
        if background { scheduleState(values, to: queueFile) }
        else { try stateDisk.write(values, to: queueFile) }
        queuedSends = values
    }

    func choice(agent: WorkshopAgent, thread: String?, application: WorkshopApplication) -> WorkshopChoice {
        preferences.choice(agentID: agent.id, thread: thread, applicationID: application.id)
    }

    func saveChoice(_ choice: WorkshopChoice, agent: WorkshopAgent, thread: String?, application: WorkshopApplication, background: Bool = false, resolvingNew: Bool = false) throws {
        guard context == scope else { throw CancellationError() }
        preferences.recordChoice(choice, agentID: agent.id, thread: thread, applicationID: application.id, resolvingNew: resolvingNew)
        try persist(background: background)
    }

    func generationDefaults(for agentID: String) -> WorkshopGenerationDefaults {
        preferences.defaultGenerations?[agentID] ?? WorkshopGenerationDefaults()
    }

    func saveGenerationDefaults(_ value: WorkshopGenerationDefaults, agent: WorkshopAgent, models: [WorkshopModel], expectedScope: String) throws {
        guard expectedScope == scope, context == scope else { throw CancellationError() }
        if let error = value.validationError(models: models) { throw HakoError(message: error) }
        let previous = preferences
        if preferences.defaultGenerations == nil { preferences.defaultGenerations = [:] }
        preferences.defaultGenerations?[agent.id] = value
        do { try persist() }
        catch { preferences = previous; throw error }
        objectWillChange.send()
    }

    private func imageFile(_ id: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw CocoaError(.fileReadInvalidFileName) }
        return cacheFile.deletingLastPathComponent().appendingPathComponent(cacheFile.deletingPathExtension().lastPathComponent, isDirectory: true)
            .appendingPathComponent(id + ".jpg")
    }

    func saveImage(_ photo: WorkshopPhoto) throws {
        let url = try imageFile(photo.id)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try photo.data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try photo.data.write(to: url, options: .atomic)
        #endif
        var directory = url.deletingLastPathComponent()
        var flags = URLResourceValues(); flags.isExcludedFromBackup = true
        try directory.setResourceValues(flags)
    }

    func savedPhoto(_ id: String) throws -> WorkshopPhoto {
        WorkshopPhoto(id: id, data: try Data(contentsOf: imageFile(id)))
    }

    func messagePhotos(_ messageID: String) -> [WorkshopPhoto] {
        let ids = preferences.receipts.first(where: { $0.id == messageID })?.imageIds ??
            (queuedSends.first(where: { $0.id == messageID })?.imageIds ?? [])
        var photos: [WorkshopPhoto] = []
        for id in ids {
            guard let photo = try? savedPhoto(id) else { break }
            photos.append(photo)
        }
        return photos
    }

    func messageImage(threadId: String, messageId: String, index: Int, agent: WorkshopAgent) async throws -> Data {
        let ticket = scope
        let identity = "\(agent.id)\n\(threadId)\n\(messageId)\n\(index)"
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        var directory = cacheFile.deletingPathExtension().appendingPathExtension("images")
        let cached = directory.appendingPathComponent(key + ".image")
        if let data = try? Data(contentsOf: cached), !data.isEmpty, data.count <= 8 * 1024 * 1024 { return data }
        let (bytes, revision) = try await WorkshopDownloadTransfer.read(id: messageId, maximum: 8 * 1024 * 1024) { offset, revision in
            var params: [String: Any] = ["threadId": threadId, "messageId": messageId, "index": index, "offset": offset]
            params["revision"] = revision
            return try await self.call(agent, "image.read", params)
        }
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard !bytes.isEmpty, hash == revision else { throw CocoaError(.coderReadCorrupt) }
        guard ticket == scope else { throw CancellationError() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        try bytes.write(to: cached, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try bytes.write(to: cached, options: .atomic)
        #endif
        var flags = URLResourceValues(); flags.isExcludedFromBackup = true
        try directory.setResourceValues(flags)
        return bytes
    }

    private func remoteImageFile(_ url: URL) -> URL {
        let key = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheFile.deletingPathExtension().appendingPathExtension("remote-images")
            .appendingPathComponent(key + ".image")
    }

    func cachedRemoteImage(_ url: URL) -> Data? {
        guard context == scope, let data = try? Data(contentsOf: remoteImageFile(url)),
              !data.isEmpty, data.count <= 8 * 1024 * 1024 else { return nil }
        return data
    }

    func cacheRemoteImage(_ data: Data, from url: URL) throws {
        guard context == scope else { throw CancellationError() }
        guard !data.isEmpty, data.count <= 8 * 1024 * 1024 else { throw HakoError(message: "图片为空或超过 8 MB，无法缓存。") }
        let file = remoteImageFile(url)
        var directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: file, options: .atomic)
        #endif
        var flags = URLResourceValues(); flags.isExcludedFromBackup = true
        try directory.setResourceValues(flags)
    }

    func uploadImages(_ ids: [String], agent: WorkshopAgent, progress: (Double) -> Void) async throws {
        let ticket = scope
        try await verifyNetworkRoute()
        let route = transportRevision
        let transport = requests(for: agent.id)
        for (index, id) in ids.enumerated() {
            let data = try Data(contentsOf: imageFile(id))
            guard !data.isEmpty, data.count <= 2_000_000 else { throw HakoError(message: "图片文件无效，请重新选择。") }
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            try await WorkshopImageTransfer.upload(id: id, data: data, initialize: {
                guard ticket == self.scope, route == self.transportRevision else { throw CancellationError() }
                return try await self.call(agent, "image.upload.begin", ["uploadId": id, "total": data.count, "sha256": hash])
            }, send: { packet in
                guard ticket == self.scope, route == self.transportRevision else { throw CancellationError() }
                let reply = try await transport.sendBinary(packet, computerID: agent.id)
                guard ticket == self.scope, route == self.transportRevision else { throw CancellationError() }
                return reply
            }, progress: { progress((Double(index) + $0) / Double(ids.count)) })
        }
    }

    func watchOperation(_ agent: WorkshopAgent, id: String, cursor: Int64,
                        receive: (WorkshopOperationPage) async throws -> Bool) async throws {
        let ticket = scope
        try await verifyNetworkRoute()
        guard ticket == scope else { throw CancellationError() }
        let route = transportRevision
        guard authenticated, UUID(uuidString: id) != nil, cursor >= 0,
              let agentID = agent.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              !agentID.contains("/") else { throw CocoaError(.coderReadCorrupt) }
        connections[agent.id] = (connections[agent.id] ?? .disconnected).beginningRequest
        do {
            var appliedCursor = cursor
            try await requests(for: agent.id).watchBatches(computerID: agent.id, operationID: id, cursor: cursor) { batch in
                let pages = try await WorkshopSocketDecoder.shared.operationPages(batch, operationID: id, after: appliedCursor)
                try Task.checkCancellation()
                guard ticket == self.scope, route == self.transportRevision else { throw CancellationError() }
                if self.connections[agent.id] != .connected { self.connections[agent.id] = .connected }
                self.uploadDiagnostics(to: agent)
                for page in pages {
                    try Task.checkCancellation()
                    guard ticket == self.scope, route == self.transportRevision else { throw CancellationError() }
                    if try await receive(page) == false { return false }
                    appliedCursor = page.cursor
                }
                return true
            }
        } catch {
            if ticket == scope, route == transportRevision {
                if let failure = error as? WorkshopFailure, ["computer_offline", "workshop_disconnected"].contains(failure.code) { cloudSockets[agent.id]?.close() }
                connections[agent.id] = (connections[agent.id] ?? .disconnected).afterFailure(error)
            }
            throw error
        }
    }

    func call<Result: Decodable>(_ agent: WorkshopAgent, _ method: String, _ params: [String: Any] = [:]) async throws -> Result {
        let ticket = scope
        try await verifyNetworkRoute()
        guard ticket == scope else { throw CancellationError() }
        let route = transportRevision
        guard authenticated else { throw HakoError(message: "请先在 Hako 设置中登录服务器。") }
        let body: [String: Any] = ["method": method, "params": params]
        guard try JSONSerialization.data(withJSONObject: body).count <= 16 * 1024 else { throw HakoError(message: "消息过长，请分段发送。") }
        // Command and account metadata reads cannot verify the conversation's connection.
        let tracksConversation = !method.hasPrefix("commands.") && !method.hasPrefix("account.")
        if tracksConversation { setConnection((connections[agent.id] ?? .disconnected).beginningRequest, for: agent.id) }
        do {
            let data = try await requests(for: agent.id).send(method, computerID: agent.id, params: params)
            guard ticket == scope, route == transportRevision else { throw CancellationError() }
            let result = try JSONDecoder().decode(Result.self, from: data)
            if tracksConversation, let index = agents.firstIndex(where: { $0.id == agent.id }), !agents[index].online {
                let current = agents[index]
                agents[index] = WorkshopAgent(id: current.id, name: current.name, online: true,
                    protocolVersion: current.protocolVersion, lan: current.lan)
            }
            if tracksConversation { setConnection(.connected, for: agent.id) }
            if tracksConversation { uploadDiagnostics(to: agent) }
            return result
        } catch {
            if ticket == scope, route == transportRevision,
               let failure = error as? WorkshopFailure, ["computer_offline", "workshop_disconnected"].contains(failure.code) {
                cloudSockets[agent.id]?.close()
            }
            if tracksConversation, ticket == scope, route == transportRevision {
                setConnection((connections[agent.id] ?? .disconnected).afterFailure(error), for: agent.id)
            }
            throw error
        }
    }

    private func setConnection(_ state: WorkshopConnectionState, for agentID: String) {
        if connections[agentID] != state { connections[agentID] = state }
    }

    func artifact(_ artifact: WorkshopArtifact, agent: WorkshopAgent) async throws -> String {
        let ticket = scope
        let key = agent.id + ":" + artifact.threadId + ":" + artifact.id
        let (bytes, revision) = try await WorkshopDownloadTransfer.read(id: artifact.id, maximum: 2 * 1024 * 1024, cached: artifactCache[key]) { offset, revision in
            var params: [String: Any] = ["threadId": artifact.threadId, "artifactId": artifact.id, "offset": offset]
            params["revision"] = revision
            return try await self.call(agent, "artifact.read", params)
        }
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard hash == revision, let html = String(data: bytes, encoding: .utf8) else { throw CocoaError(.coderReadCorrupt) }
        guard scope == ticket else { throw CancellationError() }
        if artifactCache.count >= 4, artifactCache[key] == nil, let oldest = artifactCache.keys.first { artifactCache[oldest] = nil }
        artifactCache[key] = (bytes, revision)
        return html
    }
}
