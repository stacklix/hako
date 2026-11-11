import Foundation
import Combine
import CryptoKit

@MainActor final class WorkshopStore: ObservableObject {
    let authentication: any AuthenticatedServerAccess
    private let socket: AgentRequestSocket
    private var directSocket: AgentRequestSocket?
    @Published private(set) var localEndpoint: LocalNetworkEndpoint?
    let routeChanges = PassthroughSubject<Void, Never>()
    private var networkCheck = UUID()
    private var subscription: AnyCancellable?
    private var context = ""
    private var preferences = WorkshopPreferences()
    private var cachedCatalogs: [String: WorkshopCachedCatalog] = [:]
    @Published private(set) var agents: [WorkshopAgent] = []
    @Published private(set) var applications: [WorkshopApplication] = []
    @Published private(set) var sessions: [WorkshopSession] = []
    @Published private(set) var loading = false
    @Published private(set) var showingArchived = false
    @Published private(set) var archivingSessionID: String?
    @Published var error: String?
    @Published var selectedAgentID = ""
    @Published var selectedApplicationID = ""
    @Published private(set) var cachedAt: Date?
    @Published private var readState = WorkshopReadState()
    @Published private var localSessions = WorkshopLocalSessions()
    private var cursor: String?
    private let transcriptDisk = WorkshopTranscriptDisk()

    init(authentication: (any AuthenticatedServerAccess)? = nil) {
        let authentication = authentication ?? AuthenticatedServerService.shared
        self.authentication = authentication
        socket = AgentRequestSocket(authentication: authentication, logSource: .codeWorkshop)
        subscription = authentication.changes.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.prepareContext() }
        }
        prepareContext()
    }

    var scope: String { localEndpoint.map { "local:" + $0.address } ?? authentication.requestContext }
    var authenticated: Bool { localEndpoint != nil || authentication.authenticated && !authentication.logoutPending }
    var transportLabel: String { localEndpoint.map { "局域网直连 · " + $0.address } ?? "服务器转发" }

    func prepareNetwork() async {
        let check = UUID(); networkCheck = check
        let endpoint = await LocalNetworkService.shared.endpoint(for: .codeWorkshop)
        guard !Task.isCancelled, check == networkCheck, endpoint != localEndpoint else { return }
        directSocket?.close(); directSocket = nil
        localEndpoint = endpoint
        if let endpoint {
            directSocket = AgentRequestSocket(context: { "local:" + endpoint.address }, open: {
                try await WorkshopLocalSocket.open(endpoint, path: "/agents")
            })
        }
        prepareContext()
        routeChanges.send()
    }

    private var requests: AgentRequestSocket { directSocket ?? socket }

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
        localSessions.merging(sessions, agentId: selectedAgentID, applications: applications, archived: showingArchived)
            .filter { $0.applicationId == selectedApplicationID }
    }
    var hasMore: Bool { cursor != nil }

    private func catalogKey(_ agentID: String, archived: Bool) -> String {
        archived ? agentID + ":archived" : agentID
    }

    private var cacheFile: URL {
        let digest = SHA256.hash(data: Data(context.utf8)).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodeWorkshop", isDirectory: true).appendingPathComponent(digest + ".json")
    }

    private var listCacheFile: URL {
        cacheFile.deletingLastPathComponent().appendingPathComponent(cacheFile.deletingPathExtension().lastPathComponent + "-lists.json")
    }

    private var readStateFile: URL { cacheFile.deletingPathExtension().appendingPathExtension("read.json") }

    func isUnread(_ session: WorkshopSession, at date: Date) -> Bool {
        readState.isUnread(session, agentId: selectedAgentID, now: date)
    }

    func markRead(threadId: String, completionId: String, agentId: String) {
        guard context == scope else { return }
        var updated = readState
        guard updated.markRead(threadId: threadId, completionId: completionId, agentId: agentId) else { return }
        do {
            try FileManager.default.createDirectory(at: readStateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(updated)
            #if os(iOS)
            try data.write(to: readStateFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: readStateFile, options: .atomic)
            #endif
            var file = readStateFile
            var flags = URLResourceValues(); flags.isExcludedFromBackup = true
            try file.setResourceValues(flags)
            readState = updated
        } catch { self.error = "无法保存会话已读状态。" }
    }

    private func transcriptFile(_ key: WorkshopTranscriptKey) -> URL {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let identity = (try? encoder.encode(key)) ?? Data()
        let hash = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        return cacheFile.deletingLastPathComponent()
            .appendingPathComponent("messages-" + cacheFile.deletingPathExtension().lastPathComponent, isDirectory: true)
            .appendingPathComponent(hash + ".json")
    }

    func cachedTranscript(_ key: WorkshopTranscriptKey) -> WorkshopTranscript? {
        guard context == scope else { return nil }
        return transcriptDisk.read(transcriptFile(key), key: key)
    }

    func saveTranscript(_ snapshot: WorkshopTranscript, scope ticket: String) {
        guard context == ticket, scope == ticket else { return }
        transcriptDisk.write(snapshot, to: transcriptFile(snapshot.key))
    }

    private func prepareContext() {
        guard context != scope else { return }
        context = scope
        socket.resetIfContextChanged()
        preferences = (try? JSONDecoder().decode(WorkshopPreferences.self, from: Data(contentsOf: cacheFile))) ?? WorkshopPreferences()
        localSessions = WorkshopLocalSessions()
        for receipt in preferences.receipts where receipt.state == "pending" { localSessions.record(receipt, isNew: true) }
        readState = (try? JSONDecoder().decode(WorkshopReadState.self, from: Data(contentsOf: readStateFile))) ?? WorkshopReadState()
        selectedAgentID = preferences.agentId
        selectedApplicationID = preferences.applicationId
        agents = []; applications = []; sessions = []; cursor = nil; error = nil; loading = false
        showingArchived = false; archivingSessionID = nil
        cachedCatalogs = [:]; cachedAt = nil
        if let data = try? Data(contentsOf: listCacheFile),
           let snapshot = try? JSONDecoder().decode(WorkshopListSnapshot.self, from: data) {
            cachedCatalogs = snapshot.catalogs
            // A saved list is available immediately, but cannot establish live connectivity.
            agents = snapshot.agents.map { WorkshopAgent(id: $0.id, name: $0.name, online: false, capabilities: $0.capabilities) }
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

    private func saveLists() throws {
        let values = sessions.filter { UUID(uuidString: $0.id) != nil }.prefix(300)
        cachedCatalogs[catalogKey(selectedAgentID, archived: showingArchived)] = WorkshopCachedCatalog(catalog: WorkshopCatalog(
            applications: applications, sessions: Array(values), nextCursor: cursor), savedAt: .now)
        let currentIDs = Set(agents.map(\.id))
        cachedCatalogs = cachedCatalogs.filter { item in
            currentIDs.contains(item.key) || currentIDs.contains { catalogKey($0, archived: true) == item.key }
        }
        let snapshot = WorkshopListSnapshot(agents: agents, catalogs: cachedCatalogs)
        let data = try JSONEncoder().encode(snapshot)
        var url = listCacheFile
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        var flags = URLResourceValues(); flags.isExcludedFromBackup = true
        try url.setResourceValues(flags)
    }

    private func persist() throws {
        preferences.agentId = selectedAgentID
        preferences.applicationId = selectedApplicationID
        var url = cacheFile
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try JSONEncoder().encode(preferences).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try JSONEncoder().encode(preferences).write(to: url, options: .atomic)
        #endif
        var flags = URLResourceValues(); flags.isExcludedFromBackup = true
        try url.setResourceValues(flags)
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
        guard authenticated, agent.online, agent.supportsArchiving, !loading, archivingSessionID == nil,
              UUID(uuidString: threadId) != nil else { return false }
        let ticket = scope
        archivingSessionID = threadId; error = nil
        defer { if ticket == scope { archivingSessionID = nil } }
        do {
            let reply: WorkshopArchiveReply = try await call(agent, "action.codex.thread.archive", ["threadId": threadId, "archived": archived])
            guard ticket == scope, reply.threadId == threadId, reply.archived == archived else { return false }
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

    func refresh(more: Bool = false) async {
        await prepareNetwork()
        guard authenticated, !loading, archivingSessionID == nil else { return }
        let ticket = scope
        let archived = showingArchived
        loading = true; error = nil
        defer { if scope == ticket { loading = false } }
        do {
            struct List: Decodable { let agents: [WorkshopAgent] }
            let agentData = try await requests.send("list")
            let values = try JSONDecoder().decode(List.self, from: agentData).agents
            guard ticket == scope else { return }
            let previousAgent = selectedAgentID
            agents = values
            if selectedAgent == nil {
                selectedAgentID = values.first(where: { $0.online && $0.supported })?.id ?? values.first?.id ?? ""
            }
            if previousAgent != selectedAgentID { showCachedCatalog() }
            guard let agent = selectedAgent, agent.online, agent.supported else { return }
            var params: [String: Any] = more ? cursor.map { ["cursor": $0] } ?? [:] : [:]
            if archived { params["archived"] = true }
            let previousSessions = sessions
            let page: WorkshopCatalog = try await call(agent, "query.codex.applications", params)
            guard ticket == scope, selectedAgentID == agent.id, showingArchived == archived else { return }
            // Publish the newest page before slower reconciliation of older pages.
            applications = page.applications
            sessions = WorkshopCatalog.merge(page.sessions, existing: previousSessions, more: true)
                .filter { session in applications.contains { $0.id == session.applicationId } }
            if !archived { localSessions.confirm(page.sessions, agentId: agent.id) }
            cachedAt = nil
            var freshSessions = page.sessions
            var nextCursor = page.nextCursor
            var pages = 1
            let loadedCount = min(300, previousSessions.filter { UUID(uuidString: $0.id) != nil }.count)
            // Refresh all previously loaded pages so externally archived/restored
            // threads cannot survive in a stale merged catalog.
            while !more, freshSessions.count < loadedCount, let next = nextCursor, pages < 10 {
                var nextParams: [String: Any] = ["cursor": next]
                if archived { nextParams["archived"] = true }
                let older: WorkshopCatalog = try await call(agent, "query.codex.applications", nextParams)
                guard ticket == scope, selectedAgentID == agent.id, showingArchived == archived else { return }
                freshSessions += older.sessions
                nextCursor = older.nextCursor; pages += 1
                if nextCursor == next { break }
            }
            guard ticket == scope, selectedAgentID == agent.id, showingArchived == archived else { return }
            applications = page.applications
            sessions = WorkshopCatalog.merge(freshSessions, existing: previousSessions, more: more)
                .filter { session in applications.contains { $0.id == session.applicationId } }
            if !archived { localSessions.confirm(freshSessions, agentId: agent.id) }
            cursor = nextCursor
            cachedAt = nil
            let newSessions = page.sessions.filter { !preferences.seenSessions.contains($0.id) }
            if !more && !archived {
                for session in newSessions.sorted(by: { $0.updatedAt < $1.updatedAt }) { promote(session.applicationId) }
            }
            preferences.seenSessions = Array(Set(preferences.seenSessions + page.sessions.map(\.id)))
            if !applications.contains(where: { $0.id == selectedApplicationID }) { selectedApplicationID = orderedApplications.first?.id ?? "" }
            try persist()
            try saveLists()
        } catch is CancellationError { }
        catch { if ticket == scope { self.error = error.localizedDescription } }
    }

    private func promote(_ applicationID: String) {
        preferences.order.removeAll { $0 == applicationID }
        preferences.order.insert(applicationID, at: 0)
    }

    func receipt(for session: WorkshopSession?, agent: WorkshopAgent) -> WorkshopReceipt? {
        guard let session else { return nil }
        return preferences.receipts.last { $0.agentId == agent.id && ($0.id == session.operationId || $0.threadId == session.id) }
    }

    func saveReceipt(_ receipt: WorkshopReceipt) throws {
        guard context == scope else { throw CancellationError() }
        let isNew = !preferences.receipts.contains { $0.id == receipt.id }
        if let index = preferences.receipts.firstIndex(where: { $0.id == receipt.id }) { preferences.receipts[index] = receipt }
        else {
            preferences.receipts.append(receipt)
            if preferences.receipts.count > 100 { preferences.receipts.removeFirst() }
            if receipt.originalThreadId == nil { promote(receipt.applicationId) }
        }
        try persist()
        localSessions.record(receipt, isNew: isNew)
    }

    private var queueFile: URL { cacheFile.deletingPathExtension().appendingPathExtension("queue.json") }

    func pendingQueue(operationId: String) -> [WorkshopQueuedSend] {
        (try? JSONDecoder().decode([WorkshopQueuedSend].self, from: Data(contentsOf: queueFile)))?.filter { $0.operationId == operationId } ?? []
    }

    func saveQueuedSend(_ send: WorkshopQueuedSend?, removing id: String? = nil) throws {
        guard context == scope else { throw CancellationError() }
        var values = (try? JSONDecoder().decode([WorkshopQueuedSend].self, from: Data(contentsOf: queueFile))) ?? []
        if send == nil, let id, !values.contains(where: { $0.id == id }) { return }
        if let id { values.removeAll { $0.id == id } }
        if let send { values.removeAll { $0.id == send.id }; values.append(send) }
        var url = queueFile
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try JSONEncoder().encode(values).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try JSONEncoder().encode(values).write(to: url, options: .atomic)
        #endif
        var flags = URLResourceValues(); flags.isExcludedFromBackup = true
        try url.setResourceValues(flags)
    }

    func choice(agent: WorkshopAgent, thread: String?, application: WorkshopApplication) -> WorkshopChoice {
        preferences.choices?[agent.id + ":" + (thread ?? "new-" + application.id)] ?? WorkshopChoice()
    }

    func saveChoice(_ choice: WorkshopChoice, agent: WorkshopAgent, thread: String?, application: WorkshopApplication) throws {
        guard context == scope else { throw CancellationError() }
        if preferences.choices == nil { preferences.choices = [:] }
        preferences.choices?[agent.id + ":" + (thread ?? "new-" + application.id)] = choice
        try persist()
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
            ((try? JSONDecoder().decode([WorkshopQueuedSend].self, from: Data(contentsOf: queueFile)))?
                .first(where: { $0.id == messageID })?.imageIds ?? [])
        var photos: [WorkshopPhoto] = []
        for id in ids {
            guard let photo = try? savedPhoto(id) else { break }
            photos.append(photo)
        }
        return photos
    }

    func messageImage(threadId: String, messageId: String, index: Int, agent: WorkshopAgent) async throws -> Data {
        let identity = "\(agent.id)\n\(threadId)\n\(messageId)\n\(index)"
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        var directory = cacheFile.deletingPathExtension().appendingPathExtension("images")
        let cached = directory.appendingPathComponent(key + ".image")
        if let data = try? Data(contentsOf: cached), !data.isEmpty, data.count <= 2_000_000 { return data }
        var bytes = Data()
        var revision: String?
        var total: Int?
        repeat {
            try Task.checkCancellation()
            var params: [String: Any] = ["threadId": threadId, "messageId": messageId, "index": index, "offset": bytes.count]
            params["revision"] = revision
            let chunk: WorkshopArtifactChunk = try await call(agent, "query.codex.image", params)
            guard chunk.id == messageId, chunk.offset == bytes.count, chunk.total > 0, chunk.total <= 2_000_000,
                  total == nil || total == chunk.total, revision == nil || revision == chunk.revision,
                  let decoded = Data(base64Encoded: chunk.content), !decoded.isEmpty,
                  chunk.nextOffset == bytes.count + decoded.count, chunk.nextOffset <= chunk.total else { throw CocoaError(.coderReadCorrupt) }
            revision = chunk.revision; total = chunk.total; bytes.append(decoded)
        } while bytes.count < (total ?? 0)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard hash == revision else { throw CocoaError(.coderReadCorrupt) }
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

    func uploadImages(_ ids: [String], agent: WorkshopAgent, progress: (Double) -> Void) async throws {
        let ticket = scope
        for (index, id) in ids.enumerated() {
            let data = try Data(contentsOf: imageFile(id))
            guard data.count <= 2_000_000, !data.isEmpty else { throw HakoError(message: "图片文件无效，请重新选择。") }
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            var offset = 0
            while offset < data.count {
                try Task.checkCancellation()
                guard ticket == scope else { throw CancellationError() }
                let end = min(offset + 9 * 1024, data.count)
                let reply: WorkshopUpload = try await call(agent, "action.codex.image.upload", [
                    "uploadId": id, "offset": offset, "total": data.count, "sha256": hash,
                    "content": data.subdata(in: offset..<end).base64EncodedString()
                ])
                guard reply.id == id, reply.nextOffset == end, end < data.count || reply.complete else { throw CocoaError(.coderReadCorrupt) }
                offset = end
                progress((Double(index) + Double(offset) / Double(data.count)) / Double(ids.count))
            }
        }
    }

    func watchOperation(_ agent: WorkshopAgent, id: String, cursor: Int64,
                        receive: (WorkshopOperationPage) async throws -> Bool) async throws {
        let ticket = scope
        try await verifyNetworkRoute()
        guard ticket == scope else { throw CancellationError() }
        guard authenticated, UUID(uuidString: id) != nil, cursor >= 0,
              let agentID = agent.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              !agentID.contains("/") else { throw CocoaError(.coderReadCorrupt) }
        try await WorkshopEventStream.watch(open: {
            guard ticket == self.scope else { throw CancellationError() }
            if let endpoint = self.localEndpoint {
                return try await WorkshopLocalSocket.open(endpoint, path: "/workshop/\(id)/\(cursor)")
            }
            return try await self.authentication.openWebSocket(
                "/ws/console/agents/workshop/\(agentID)/\(id)/\(cursor)", logSource: .codeWorkshop)
        }, receive: { (page: WorkshopOperationPage) in
            guard ticket == self.scope else { throw CancellationError() }
            return try await receive(page)
        })
    }

    func call<Result: Decodable>(_ agent: WorkshopAgent, _ method: String, _ params: [String: Any] = [:]) async throws -> Result {
        let ticket = scope
        try await verifyNetworkRoute()
        guard ticket == scope else { throw CancellationError() }
        guard authenticated else { throw HakoError(message: "请先在 Hako 设置中登录服务器。") }
        let body: [String: Any] = ["method": method, "version": 1, "params": params]
        guard try JSONSerialization.data(withJSONObject: body).count <= 16 * 1024 else { throw HakoError(message: "消息过长，请分段发送。") }
        let data = try await requests.send("request", agentID: agent.id, body: body)
        guard ticket == scope else { throw CancellationError() }
        let reply = try JSONDecoder().decode(WorkshopReply<Result>.self, from: data)
        if let failure = reply.error { throw failure }
        guard let result = reply.result else { throw CocoaError(.coderReadCorrupt) }
        return result
    }

    func artifact(_ artifact: WorkshopArtifact, agent: WorkshopAgent) async throws -> String {
        var bytes = Data()
        var revision: String?
        var total: Int?
        repeat {
            var params: [String: Any] = ["threadId": artifact.threadId, "artifactId": artifact.id, "offset": bytes.count]
            params["revision"] = revision
            let chunk: WorkshopArtifactChunk = try await call(agent, "query.codex.artifact", params)
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
