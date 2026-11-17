import Foundation
import Combine
import CryptoKit

@MainActor final class WorkshopStore: ObservableObject {
    let authentication: any AuthenticatedServerAccess
    private let socket: WorkshopRequestSocket
    private var directSocket: WorkshopRequestSocket?
    @Published private(set) var localEndpoint: LocalNetworkEndpoint?
    let routeChanges = PassthroughSubject<Void, Never>()
    private var networkCheck = UUID()
    private var transportRevision = UUID()
    private var connectionPersistent = false
    private var subscription: AnyCancellable?
    private var context = ""
    private var preferences = WorkshopPreferences()
    private var cachedCatalogs: [String: WorkshopCachedCatalog] = [:]
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
    private var sessionUpdates = WorkshopSessionUpdates()
    private var activityChecks: [String: ContinuousClock.Instant] = [:]
    private let transcriptDisk = WorkshopTranscriptDisk()
    private let stateDisk = WorkshopPersistence()
    private var queuedSends: [WorkshopQueuedSend] = []
    private let draftWriter = WorkshopDraftWriter()
    private var draftCache: [URL: WorkshopComposerDraft] = [:]

    init(authentication: (any AuthenticatedServerAccess)? = nil) {
        let authentication = authentication ?? AuthenticatedServerService.shared
        self.authentication = authentication
        socket = WorkshopRequestSocket(authentication: authentication, logSource: .codeWorkshop)
        socket.onDisconnect = { [weak self] in self?.connectionInterrupted() }
        socket.onFailure = { HakoLog.record(.codeWorkshop, "工坊共享连接中断", detail: $0.localizedDescription) }
        subscription = authentication.changes.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.prepareContext() }
        }
        prepareContext()
    }

    // Authorization fences in-flight work; neither it nor the route identifies disk data.
    var scope: String { authentication.requestContext }
    var authenticated: Bool { localEndpoint != nil || authentication.authenticated && !authentication.logoutPending }
    var transportLabel: String { localEndpoint.map { "局域网直连 · " + $0.address } ?? "服务器转发" }

    func prepareNetwork() async {
        let check = UUID(); networkCheck = check
        let endpoint = await LocalNetworkService.shared.endpoint(for: .codeWorkshop)
        guard !Task.isCancelled, check == networkCheck, endpoint != localEndpoint else { return }
        socket.close()
        directSocket?.close(); directSocket = nil
        transportRevision = UUID()
        connections.removeAll()
        catalogRevision = UUID()
        loading = false
        localEndpoint = endpoint
        if let endpoint {
            directSocket = WorkshopRequestSocket(context: { "local:" + endpoint.address }, open: {
                try await WorkshopLocalSocket.open(endpoint, path: "/workshop/v1")
            })
            directSocket?.onDisconnect = { [weak self] in self?.connectionInterrupted() }
            directSocket?.onFailure = { HakoLog.record(.codeWorkshop, "工坊局域网共享连接中断", detail: $0.localizedDescription) }
            directSocket?.setPersistent(connectionPersistent)
        }
        prepareContext()
        routeChanges.send()
    }

    private var requests: WorkshopRequestSocket { directSocket ?? socket }

    func setConnectionForeground(_ foreground: Bool) {
        connectionPersistent = foreground
        socket.setPersistent(foreground); directSocket?.setPersistent(foreground)
    }

    private func connectionInterrupted() {
        for (id, state) in connections where state != .disconnected { connections[id] = .reconnecting }
    }

    private func verifyNetworkRoute() async throws {
        let expected = localEndpoint
        let current = await LocalNetworkService.shared.endpoint(for: .codeWorkshop)
        try Task.checkCancellation()
        guard current == expected else {
            await prepareNetwork()
            throw CancellationError()
        }
    }
    var selectedAgent: WorkshopAgent? { agents.first { $0.id == selectedAgentID } }
    var selectedApplication: WorkshopApplication? { applications.first { $0.id == selectedApplicationID } }
    var orderedApplications: [WorkshopApplication] {
        preferences.order.compactMap { id in applications.first { $0.id == id } }
            + applications.filter { !preferences.order.contains($0.id) }
    }
    var visibleSessions: [WorkshopSession] {
        let visible = localSessions.merging(sessions, agentId: selectedAgentID, applications: applications, archived: showingArchived)
            .filter { $0.applicationId == selectedApplicationID }
        let now = Date()
        return WorkshopCatalog.prioritizing(visible,
            draftIDs: Set(visible.filter { hasDraft($0) }.map(\.id)),
            unreadIDs: Set(visible.filter { isUnread($0, at: now) }.map(\.id)))
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
        var flags = URLResourceValues(); flags.isExcludedFromBackup = true
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
            operationId: operationId, completionId: state == "completed" ? completionId : nil, lastSentAt: previous.lastSentAt)
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
        sessionUpdates = WorkshopSessionUpdates()
        activityChecks.removeAll()
        connections.removeAll()
        socket.resetIfContextChanged()
        preferences = (try? stateDisk.read(WorkshopPreferences.self, from: cacheFile)) ?? WorkshopPreferences()
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
            cachedCatalogs = snapshot.catalogs
            // A saved list is available immediately, but cannot establish live connectivity.
            agents = snapshot.agents.map { WorkshopAgent(id: $0.id, name: $0.name, online: false, protocolVersion: $0.protocolVersion) }
            if selectedAgent == nil { selectedAgentID = agents.first?.id ?? "" }
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
        cachedCatalogs[catalogKey(selectedAgentID, archived: showingArchived)] = WorkshopCachedCatalog(catalog: WorkshopCatalog(
            applications: applications, sessions: Array(values), nextCursor: cursor), savedAt: .now)
        // A direct connection exposes only its own computer. Its inventory is not
        // evidence that cached catalogs for other computers should be deleted.
        let snapshot = WorkshopListSnapshot(agents: agents, catalogs: cachedCatalogs)
        if background { scheduleState(snapshot, to: listCacheFile) }
        else { try stateDisk.write(snapshot, to: listCacheFile) }
    }

    private func persist(background: Bool = false) throws {
        preferences.agentId = selectedAgentID
        preferences.applicationId = selectedApplicationID
        if background { scheduleState(preferences, to: cacheFile) }
        else { try stateDisk.write(preferences, to: cacheFile) }
    }

    private func scheduleState<Value: Encodable & Sendable>(_ value: Value, to file: URL) {
        let ticket = scope
        stateDisk.schedule(value, to: file) { [weak self] result in
            if case .failure = result {
                Task { @MainActor [weak self] in
                    guard let self, self.scope == ticket else { return }
                    self.error = "无法保存代码工坊状态，请检查设备存储空间。"
                }
            }
        }
    }

    func selectApplication(_ id: String) {
        selectedApplicationID = id
        do { try persist() } catch { self.error = "无法保存应用选择。" }
    }

    func selectArchiveMode(_ archived: Bool) async {
        guard archived != showingArchived, !loading, archivingSessionID == nil,
              !archived || selectedAgent?.supportsArchiving == true else { return }
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
        guard id != selectedAgentID else { return }
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
        while loading {
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

    func refresh(more: Bool = false) async {
        await prepareNetwork()
        guard authenticated, !loading, !loadingMore || more, archivingSessionID == nil,
              !more || hasMore else { return }
        let ticket = scope
        let revision = catalogRevision
        let sessionCheckpoint = sessionUpdates.revision
        let archived = showingArchived
        loading = true
        defer { if scope == ticket, revision == catalogRevision { loading = false } }
        do {
            struct List: Decodable { let computers: [WorkshopAgent] }
            let agentData = try await requests.send("computers.list")
            let values = try JSONDecoder().decode(List.self, from: agentData).computers
            guard ticket == scope, revision == catalogRevision else { return }
            let previousAgent = selectedAgentID
            agents = values
            for agent in values where !agent.online { connections[agent.id] = .disconnected }
            if selectedAgent == nil {
                selectedAgentID = values.first(where: { $0.online && $0.supported })?.id ?? values.first?.id ?? ""
            }
            if previousAgent != selectedAgentID { showCachedCatalog() }
            guard let agent = selectedAgent, agent.online, agent.supported else { return }
            var params: [String: Any] = more ? cursor.map { ["cursor": $0] } ?? [:] : [:]
            if archived { params["archived"] = true }
            let previousSessions = sessions
            let page: WorkshopCatalog = try await call(agent, "applications.list", params)
            guard ticket == scope, revision == catalogRevision, selectedAgentID == agent.id, showingArchived == archived else { return }
            // Publish the newest page before slower reconciliation of older pages.
            applications = page.applications
            sessions = WorkshopCatalog.merge(sessionUpdates.merging(page.sessions, agentId: agent.id, since: sessionCheckpoint), existing: previousSessions, more: true)
                .filter { session in applications.contains { $0.id == session.applicationId } }
            if !archived { confirmSessions(page.sessions, agentId: agent.id) }
            cachedAt = nil
            var freshSessions = page.sessions
            var nextCursor = page.nextCursor
            let loadedCount = previousSessions.filter { UUID(uuidString: $0.id) != nil }.count
            var visited = Set<String>()
            // Refresh all previously loaded pages so externally archived/restored
            // threads cannot survive in a stale merged catalog.
            while !more, freshSessions.count < loadedCount, let next = nextCursor, visited.insert(next).inserted {
                var nextParams: [String: Any] = ["cursor": next]
                if archived { nextParams["archived"] = true }
                let older: WorkshopCatalog = try await call(agent, "applications.list", nextParams)
                guard ticket == scope, revision == catalogRevision, selectedAgentID == agent.id, showingArchived == archived else { return }
                freshSessions += older.sessions
                nextCursor = older.nextCursor
                if nextCursor == next { break }
            }
            guard ticket == scope, revision == catalogRevision, selectedAgentID == agent.id, showingArchived == archived else { return }
            applications = page.applications
            sessions = WorkshopCatalog.merge(sessionUpdates.merging(freshSessions, agentId: agent.id, since: sessionCheckpoint), existing: previousSessions, more: more)
                .filter { session in applications.contains { $0.id == session.applicationId } }
            if !archived { confirmSessions(freshSessions, agentId: agent.id) }
            cursor = nextCursor
            cachedAt = nil
            let newSessions = page.sessions.filter { !preferences.seenSessions.contains($0.id) }
            if !more && !archived {
                for session in newSessions.sorted(by: { $0.lastSentAt < $1.lastSentAt }) { promote(session.applicationId) }
            }
            preferences.seenSessions = Array(Set(preferences.seenSessions + page.sessions.map(\.id)))
            if !applications.contains(where: { $0.id == selectedApplicationID }) { selectedApplicationID = orderedApplications.first?.id ?? "" }
            try persist()
            try saveLists()
            error = nil
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
        localSessions.confirm(sessions, agentId: agentId)
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
        preferences.choices?[agent.id + ":" + (thread ?? "new-" + application.id)] ?? WorkshopChoice()
    }

    func saveChoice(_ choice: WorkshopChoice, agent: WorkshopAgent, thread: String?, application: WorkshopApplication, background: Bool = false) throws {
        guard context == scope else { throw CancellationError() }
        if preferences.choices == nil { preferences.choices = [:] }
        preferences.choices?[agent.id + ":" + (thread ?? "new-" + application.id)] = choice
        try persist(background: background)
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
        var bytes = Data()
        var revision: String?
        var total: Int?
        repeat {
            try Task.checkCancellation()
            var params: [String: Any] = ["threadId": threadId, "messageId": messageId, "index": index, "offset": bytes.count]
            params["revision"] = revision
            let chunk: WorkshopArtifactChunk = try await call(agent, "image.read", params)
            guard chunk.id == messageId, chunk.offset == bytes.count, chunk.total > 0, chunk.total <= 8 * 1024 * 1024,
                  total == nil || total == chunk.total, revision == nil || revision == chunk.revision,
                  let decoded = Data(base64Encoded: chunk.content), !decoded.isEmpty,
                  chunk.nextOffset == bytes.count + decoded.count, chunk.nextOffset <= chunk.total else { throw CocoaError(.coderReadCorrupt) }
            revision = chunk.revision; total = chunk.total; bytes.append(decoded)
        } while bytes.count < (total ?? 0)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard hash == revision else { throw CocoaError(.coderReadCorrupt) }
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
        let transport = requests
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
            try await requests.watchBatches(computerID: agent.id, operationID: id, cursor: cursor) { batch in
                let pages = try await WorkshopSocketDecoder.shared.operationPages(batch, operationID: id, after: appliedCursor)
                try Task.checkCancellation()
                guard ticket == self.scope, route == self.transportRevision else { throw CancellationError() }
                if self.connections[agent.id] != .connected { self.connections[agent.id] = .connected }
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
        // Shortcut commands use a separate Agent channel, so they cannot verify
        // the conversation's connection.
        let tracksConversation = !method.hasPrefix("commands.")
        if tracksConversation { connections[agent.id] = (connections[agent.id] ?? .disconnected).beginningRequest }
        do {
            let data = try await requests.send(method, computerID: agent.id, params: params)
            guard ticket == scope, route == transportRevision else { throw CancellationError() }
            let result = try JSONDecoder().decode(Result.self, from: data)
            if tracksConversation { connections[agent.id] = .connected }
            return result
        } catch {
            if tracksConversation, ticket == scope, route == transportRevision {
                connections[agent.id] = (connections[agent.id] ?? .disconnected).afterFailure(error)
            }
            throw error
        }
    }

    func artifact(_ artifact: WorkshopArtifact, agent: WorkshopAgent) async throws -> String {
        var bytes = Data()
        var revision: String?
        var total: Int?
        repeat {
            var params: [String: Any] = ["threadId": artifact.threadId, "artifactId": artifact.id, "offset": bytes.count]
            params["revision"] = revision
            let chunk: WorkshopArtifactChunk = try await call(agent, "artifact.read", params)
            guard chunk.id == artifact.id, chunk.offset == bytes.count, chunk.total <= 2 * 1024 * 1024,
                  chunk.total >= 0, total == nil || total == chunk.total, revision == nil || revision == chunk.revision,
                  let decoded = Data(base64Encoded: chunk.content), chunk.nextOffset == bytes.count + decoded.count,
                  chunk.nextOffset <= chunk.total, !decoded.isEmpty || chunk.total == 0 else { throw CocoaError(.coderReadCorrupt) }
            revision = chunk.revision; total = chunk.total; bytes.append(decoded)
        } while bytes.count < (total ?? 0)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard hash == revision, let html = String(data: bytes, encoding: .utf8) else { throw CocoaError(.coderReadCorrupt) }
        return html
    }
}
