import Foundation
import Combine

@MainActor final class WorkshopConversation: ObservableObject, Identifiable {
    let id = UUID()
    let store: WorkshopStore
    let agent: WorkshopAgent
    let application: WorkshopApplication
    let title: String
    let scope: String
    @Published private(set) var threadId: String? { didSet { persistDraft() } }
    @Published private(set) var isArchived: Bool
    @Published private(set) var entries: [WorkshopEntry] = []
    @Published private(set) var artifacts: [WorkshopArtifact] = []
    @Published private(set) var operation: WorkshopOperation?
    @Published private(set) var approvals: [WorkshopApproval] = []
    @Published private(set) var historyCursor: String?
    @Published private(set) var busy = false
    @Published private(set) var loadingHistory = false
    @Published private(set) var uncertain = false
    @Published var draft = "" { didSet { composerChanged() } }
    @Published var error: String?
    @Published private(set) var connectionIssue: String?
    @Published private(set) var photos: [WorkshopPhoto] = [] { didSet { composerChanged() } }
    @Published private(set) var uploadProgress: Double?
    @Published private(set) var models: [WorkshopModel] = []
    @Published private(set) var loadingModels = false
    @Published private(set) var modelError: String?
    @Published private(set) var choice = WorkshopChoice()
    @Published private(set) var followups: [WorkshopFollowupState] = []
    @Published private(set) var editingMessageID: String? { didSet { persistDraft() } }
    @Published private(set) var appendedMessageID: String?
    @Published private(set) var cachedAt: Date?
    @Published private(set) var synchronizing = false
    private var editingDraft: (text: String, photos: [WorkshopPhoto])? { didSet { persistDraft() } }
    private var draftReady = false
    private var draftSessionID = "new"
    private var savedDraft: WorkshopComposerDraft?
    private var draftSendingID: String? { didSet { persistDraft() } }
    private var receipt: WorkshopReceipt?
    private var operationId: String? {
        didSet {
            if oldValue != operationId { eventStream?.cancel() }
            persistDraft()
        }
    }
    private var eventStream: Task<Void, Error>?
    private var eventCursor: Int64 = 0
    private var observedTerminal: String?
    private var hasMoreEvents = false
    private var polling = false
    private var streamText: [String: String] = [:]
    private var savedTranscript: WorkshopTranscript?
    private var readingLatest = false
    private var latestCompletionID: String?
    private var lastVerifiedAt: Date?
    private var catalogHint: WorkshopSession?
    private var needsHistoryRefresh = false

    init(store: WorkshopStore, agent: WorkshopAgent, application: WorkshopApplication, session: WorkshopSession? = nil, title: String? = nil, archived: Bool = false) {
        self.store = store; self.agent = agent; self.application = application
        self.title = title ?? session?.title ?? "新会话"
        scope = store.scope
        catalogHint = session
        isArchived = archived
        threadId = session.flatMap { UUID(uuidString: $0.id) == nil ? nil : $0.id }
        receipt = store.receipt(for: session, agent: agent)
        operationId = session?.operationId ?? receipt?.id
        if let receipt, receipt.id == operationId, receipt.state == "pending" { uncertain = true }
        choice = store.choice(agent: agent, thread: threadId, application: application)
        if let threadId, let snapshot = store.cachedTranscript(WorkshopTranscriptKey(agentId: agent.id, applicationId: application.id, threadId: threadId)) {
            entries = snapshot.entries; artifacts = snapshot.artifacts; followups = snapshot.followups
            historyCursor = snapshot.historyCursor; cachedAt = snapshot.savedAt
            if operationId == nil { operationId = snapshot.operationId }
            if operationId == snapshot.operationId { eventCursor = snapshot.eventCursor; streamText = snapshot.streamText }
            savedTranscript = snapshot
            uncertain = operationId != nil
        }
        if let operationId {
            for pending in store.pendingQueue(operationId: operationId) where !entries.contains(where: { $0.id == pending.id }) { entries.append(pending.entry) }
        }
        draftSessionID = composerSessionID
        do {
            var saved = try store.composerDraft(agent: agent, application: application, sessionId: draftSessionID)
            // A new session can become visible in the catalog before this app
            // receives its thread ID. Its input still belongs to the request.
            if saved == nil, let operationId, draftSessionID != "pending-" + operationId,
               let pending = try store.composerDraft(agent: agent, application: application, sessionId: "pending-" + operationId) {
                saved = pending; draftSessionID = "pending-" + operationId
            }
            if let saved {
                draft = saved.input.text
                photos = try saved.input.imageIds.map { try store.savedPhoto($0) }
                editingMessageID = saved.editingMessageID
                if let original = saved.originalInput {
                    editingDraft = (original.text, try original.imageIds.map { try store.savedPhoto($0) })
                }
                savedDraft = saved
                draftSendingID = saved.sendingMessageID
            }
        } catch { self.error = "无法完整恢复输入草稿。\(error.localizedDescription)" }
        draftReady = true
        if savedDraft != nil { persistDraft() }
    }

    private var composerSessionID: String { threadId ?? operationId.map { "pending-" + $0 } ?? "new:" + title }

    private var composerDraft: WorkshopComposerDraft {
        WorkshopComposerDraft(input: WorkshopDraftInput(text: draft, imageIds: photos.map(\.id)),
            editingMessageID: editingMessageID,
            originalInput: editingDraft.map { WorkshopDraftInput(text: $0.text, imageIds: $0.photos.map(\.id)) },
            sendingMessageID: draftSendingID)
    }

    private func persistDraft() {
        guard draftReady, scope == store.scope else { return }
        let snapshot = composerDraft
        let sessionID = composerSessionID
        guard snapshot != savedDraft || sessionID != draftSessionID else { return }
        do {
            try store.saveComposerDraft(snapshot, agent: agent, application: application, sessionId: sessionID,
                previousSessionId: draftSessionID, scope: scope)
            draftSessionID = sessionID; savedDraft = snapshot
        } catch { self.error = "输入尚在本页，但草稿保存失败，请勿退出。\(error.localizedDescription)" }
    }

    private func composerChanged() {
        if draftReady { draftSendingID = nil }
        persistDraft()
    }

    private func clearSentDraft(_ message: String, imageIds: [String], id: String) {
        guard composerDraft.matchesSentMessage(message, imageIds: imageIds, id: id) else { return }
        draft = ""; photos = []
    }

    var canCompose: Bool { !isArchived && !busy && store.authenticated && scope == store.scope }
    var canConfigure: Bool { !isArchived && store.authenticated && scope == store.scope }
    var canSubmitMessage: Bool { canCompose && !synchronizing && !uncertain }
    var canEditMessages: Bool { canSubmitMessage && !hasMoreEvents }
    var hasDraftInput: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !photos.isEmpty ||
        (editingMessageID != nil && followups.contains { $0.id == editingMessageID && !$0.imageIds.isEmpty }) }
    var canRetry: Bool { !isArchived && uncertain && receipt?.id == operationId && receipt?.state == "pending" && !busy && !synchronizing && operation?.active != true }
    var modelLabel: String { models.first { $0.id == choice.model }?.name ?? choice.model ?? "跟随会话设置" }

    var reuseKey: WorkshopConversationReuseKey? {
        guard let sessionId = threadId ?? operationId.map({ "pending-" + $0 }) else { return nil }
        return WorkshopConversationReuseKey(scope: scope, agentId: agent.id, applicationId: application.id,
            sessionId: sessionId, archived: isArchived)
    }

    func prepareForReentry(_ session: WorkshopSession) {
        if WorkshopWatchStep.catalogNeedsSynchronization(previous: catalogHint, current: session,
            operationId: operationId, operationActive: operation?.active == true, completionId: latestCompletionID) {
            lastVerifiedAt = nil
            needsHistoryRefresh = true
            eventStream?.cancel()
        }
        catalogHint = session
    }

    func loadModels() async {
        guard !loadingModels else { return }
        loadingModels = true; modelError = nil
        defer { loadingModels = false }
        do {
            let result: WorkshopModelList = try await store.call(agent, "models.list")
            guard scope == store.scope else { return }
            models = result.models
        } catch is CancellationError { }
        catch { modelError = error.localizedDescription }
    }

    func configure(_ next: WorkshopChoice) throws {
        guard canConfigure else { throw HakoError(message: "当前会话不可修改设置，请确认登录状态且会话未归档。") }
        let selected = models.first { $0.id == next.model } ?? (next.model == nil ? models.first { $0.isDefault } : nil)
        if let tier = next.serviceTier, tier != "default", selected?.serviceTiers.contains(where: { $0.id == tier }) != true {
            throw HakoError(message: "所选模型暂不支持此速度，请刷新模型列表后重新选择。")
        }
        try store.saveChoice(next, agent: agent, thread: threadId, application: application)
        choice = next
    }

    func attach(_ data: Data) throws {
        guard canCompose, editingMessageID == nil, photos.count < 3, data.count <= 2_000_000 else { throw HakoError(message: "每条消息最多添加 3 张图片。") }
        let photo = WorkshopPhoto(id: UUID().uuidString.lowercased(), data: data)
        try store.saveImage(photo)
        photos.append(photo)
    }

    func removePhoto(_ id: String) { if canCompose { photos.removeAll { $0.id == id } } }

    func setReadingLatest(_ visible: Bool) {
        readingLatest = visible
        markLatestRead()
    }

    private func markLatestRead() {
        guard readingLatest, scope == store.scope, let threadId, let latestCompletionID else { return }
        store.markRead(threadId: threadId, completionId: latestCompletionID, agentId: agent.id)
    }

    func unarchive() async {
        guard isArchived, !busy, let threadId else { return }
        busy = true
        defer { busy = false }
        if await store.setArchived(threadId, archived: false, agent: agent) {
            isArchived = false; error = nil
        } else { error = store.error ?? "暂时无法取消归档，请稍后重试。" }
    }

    @discardableResult func loadHistory(more: Bool = false) async -> Bool {
        guard let threadId, !loadingHistory, scope == store.scope else { return false }
        loadingHistory = true
        defer { loadingHistory = false }
        do {
            let originalOperation = operationId
            let existingIDs = Set(entries.filter { $0.kind != "followup" }.map(\.id))
            let previousCursor = historyCursor
            var params: [String: Any] = ["threadId": threadId]
            if more { params["cursor"] = historyCursor }
            var result: WorkshopHistory = try await store.call(agent, "history.read", params)
            guard scope == store.scope, result.threadId == threadId else { return false }
            let newestOperation = result.operationId
            let newestArtifacts = result.artifacts
            let newestCursor = result.nextCursor
            var page = result.entries
            var pages = 1
            // Fill a gap since the cached tail, or skip older pages already in the cache.
            while let cursor = result.nextCursor, pages < 32,
                  more ? result.entries.allSatisfy({ existingIDs.contains($0.id) }) :
                    (!existingIDs.isEmpty && !page.contains(where: { existingIDs.contains($0.id) })) {
                try Task.checkCancellation()
                let next: WorkshopHistory = try await store.call(agent, "history.read", ["threadId": threadId, "cursor": cursor])
                guard scope == store.scope, next.threadId == threadId, next.nextCursor != cursor else { break }
                result = next; page = next.entries + page; pages += 1
            }
            guard scope == store.scope else { return false }
            entries = WorkshopTranscriptMerge.history(entries, page: page)
            if more {
                historyCursor = result.nextCursor
            } else {
                let overlaps = page.contains { existingIDs.contains($0.id) }
                historyCursor = overlaps && previousCursor != nil ? previousCursor : newestCursor
            }
            for artifact in newestArtifacts where !artifacts.contains(where: { $0.id == artifact.id }) { artifacts.append(artifact) }
            cachedAt = nil
            connectionIssue = nil
            error = nil
            if !more { latestCompletionID = result.completionId; markLatestRead() }
            if !more, operationId == originalOperation, let newestOperation, newestOperation != operationId {
                operationId = newestOperation; operation = nil; eventCursor = 0; streamText = [:]
                observedTerminal = nil; uncertain = true; followups = []
                if receipt?.id != newestOperation { receipt = nil }
            }
            if !more, operationId == nil {
                operationId = newestOperation
                if let operationId {
                    for pending in store.pendingQueue(operationId: operationId) where !entries.contains(where: { $0.id == pending.id }) { entries.append(pending.entry) }
                }
            }
            if !more, !uncertain, operationId == nil || observedTerminal == operationId { lastVerifiedAt = .now }
            saveTranscript()
            return true
        } catch { readFailed(error); return false }
    }

    func watch() async {
        guard !Task.isCancelled, scope == store.scope else { return }
        let entryStep = WorkshopWatchStep.onEntry(lastVerifiedAt: lastVerifiedAt,
            operationId: operationId, observedTerminal: observedTerminal,
            needsRecovery: needsHistoryRefresh || connectionIssue != nil || uncertain, busy: busy || synchronizing)
        if entryStep == .synchronize { await synchronize() }
        // A completed/external conversation only needs its latest history page;
        // keep the verified composer usable while checking for changes.
        else if entryStep == .idle, !busy, !synchronizing, threadId != nil { await loadHistory() }
        var failures = 0
        var idleChecks = 0
        while !Task.isCancelled, scope == store.scope {
            switch WorkshopWatchStep.next(operationId: operationId, observedTerminal: observedTerminal,
                needsRecovery: needsHistoryRefresh || connectionIssue != nil || uncertain, busy: busy || synchronizing) {
            case .synchronize:
                idleChecks = 0
                await synchronize()
                failures = connectionIssue == nil ? 0 : failures + 1
            case .poll(let operationId):
                idleChecks = 0
                do {
                    let stream = Task {
                        try await store.watchOperation(agent, id: operationId, cursor: eventCursor) { page in
                            try Task.checkCancellation()
                            guard self.operationId == operationId else { throw CancellationError() }
                            try await self.accept(page, id: operationId)
                            return self.observedTerminal != operationId
                        }
                    }
                    eventStream = stream
                    defer { eventStream = nil }
                    try await withTaskCancellationHandler { try await stream.value } onCancel: { stream.cancel() }
                    failures = 0
                } catch {
                    guard !Task.isCancelled, scope == store.scope else { return }
                    if self.operationId != operationId { continue }
                    if error is CancellationError || (error as NSError).code == NSURLErrorCancelled { continue }
                    failures += 1
                    readFailed(error)
                }
            case .idle:
                if !busy && !synchronizing {
                    idleChecks += 1
                    if idleChecks >= 10 { idleChecks = 0; await loadHistory() }
                }
            }
            do { try await Task.sleep(for: .milliseconds(hasMoreEvents ? 30 : min(15, 1 + failures * 2) * 1000)) }
            catch { return }
        }
    }

    func synchronize() async {
        guard !synchronizing, scope == store.scope else { return }
        synchronizing = true
        defer { synchronizing = false }
        if let stream = eventStream {
            stream.cancel()
            _ = try? await stream.value
            eventStream = nil
        }
        if operationId != nil { uncertain = true }
        let loadedHistory = await loadHistory()
        guard !Task.isCancelled, scope == store.scope else { return }
        guard threadId == nil || loadedHistory else { return }
        if let operationId {
            do { try await poll(operationId); needsHistoryRefresh = false }
            catch { readFailed(error) }
        } else { needsHistoryRefresh = false }
    }

    private func saveTranscript() {
        guard let threadId, scope == store.scope else { return }
        let snapshot = WorkshopTranscript(key: WorkshopTranscriptKey(agentId: agent.id, applicationId: application.id, threadId: threadId),
            entries: entries, artifacts: artifacts, followups: followups, historyCursor: historyCursor, operationId: operationId,
            eventCursor: eventCursor, streamText: streamText, savedAt: .now)
        guard savedTranscript.map({ !snapshot.hasSameContent(as: $0) }) ?? true else { return }
        savedTranscript = snapshot
        store.saveTranscript(snapshot, scope: scope)
    }

    private func poll(_ id: String) async throws {
        guard !polling, eventStream == nil else { return }
        polling = true
        defer { polling = false }
        let result: WorkshopOperationPage = try await store.call(agent, "operation.read", ["operationId": id, "cursor": eventCursor])
        try await accept(result, id: id)
    }

    private func accept(_ result: WorkshopOperationPage, id: String) async throws {
        guard scope == store.scope, operationId == id, result.operation.id == id, result.cursor >= eventCursor else { throw CancellationError() }
        operation = result.operation
        connectionIssue = nil
        uncertain = false
        cachedAt = nil
        followups = result.followups
        if let receipt, receipt.id == id { clearSentDraft(receipt.message, imageIds: receipt.imageIds ?? [], id: id) }
        if result.cursor > eventCursor { for event in result.events { apply(event) } }
        for followup in followups {
            if let queued = pendingSend(followup.id) { clearSentDraft(queued.message, imageIds: queued.imageIds, id: queued.id) }
            try store.saveQueuedSend(nil, removing: followup.id)
            if followup.state == "cancelled" { entries.removeAll { $0.id == followup.id }; continue }
            if let index = entries.firstIndex(where: { $0.id == followup.id && $0.kind == "followup" }) {
                let entry = entries[index]
                entries[index] = WorkshopEntry(kind: entry.kind, id: entry.id, text: entry.text, role: entry.role,
                    state: followup.state, truncated: entry.truncated)
            }
        }
        hasMoreEvents = result.hasMore && result.cursor > eventCursor
        eventCursor = result.cursor
        approvals = result.approvals
        for artifact in result.artifacts where !artifacts.contains(where: { $0.id == artifact.id }) { artifacts.append(artifact) }
        if let resolved = result.operation.threadId {
            if threadId == nil { try store.saveChoice(choice, agent: agent, thread: resolved, application: application) }
            threadId = resolved
        }
        if var receipt, receipt.id == id {
            receipt.threadId = threadId
            receipt.state = result.operation.active ? "pending" : result.operation.state
            try store.saveReceipt(receipt)
            self.receipt = receipt
        }
        saveTranscript()
        lastVerifiedAt = .now
        if !result.operation.active && !result.hasMore {
            observedTerminal = id
            if result.operation.state == "completed" { latestCompletionID = result.operation.turnId; markLatestRead() }
            if let message = result.operation.message, !message.isEmpty { error = message }
            if result.operation.state == "completed" || result.operation.state == "interrupted" { await loadHistory() }
            await store.refresh()
        }
    }

    private func apply(_ event: WorkshopEntry) {
        WorkshopTranscriptMerge.apply(event, entries: &entries, streamText: &streamText)
    }

    func send() async {
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSubmitMessage, hasDraftInput else { return }
        guard message.utf16.count <= 4000 else { error = "消息最多 4,000 个字符，请分段发送。"; return }
        if let id = editingMessageID {
            await mutateMessage(id, action: "update", message: message)
            return
        }
        if let id = draftSendingID, let queued = pendingSend(id) {
            await submitQueued(queued)
            return
        }
        if !photos.isEmpty, let model = models.first(where: { $0.id == choice.model }), !model.supportsImages {
            error = "当前模型不支持图片，请在更多页面选择支持图片的模型。"; return
        }
        if let operationId, operation?.active == true || followups.contains(where: { $0.editable }) {
            let resume = operation?.active != true
            let queued = WorkshopQueuedSend(id: UUID().uuidString.lowercased(), operationId: operationId,
                message: message, imageIds: photos.map(\.id))
            do { try store.saveQueuedSend(queued) }
            catch { self.error = "无法保存排队消息，请重试。"; return }
            store.recordQueuedActivity(queued, agent: agent, application: application, threadId: threadId, title: title, scope: scope)
            draftSendingID = queued.id
            entries.append(queued.entry); appendedMessageID = queued.id; error = nil
            saveTranscript()
            await submitQueued(queued)
            if resume, followups.contains(where: { $0.id == queued.id && $0.editable }) {
                await mutateMessage(queued.id, action: "steer")
            }
            return
        }
        let next = WorkshopReceipt(id: UUID().uuidString.lowercased(), agentId: agent.id, applicationId: application.id,
            originalThreadId: threadId, threadId: threadId, title: title, message: message, createdAt: .now, state: "pending",
            model: choice.model, permission: choice.permission.rawValue, imageIds: photos.isEmpty ? nil : photos.map(\.id),
            serviceTier: choice.serviceTier ?? "default")
        do { try store.saveReceipt(next) }
        catch { self.error = "无法保存发送记录，请重试。"; return }
        draftSendingID = next.id
        receipt = next; uncertain = true; operationId = next.id; eventCursor = 0; streamText = [:]; observedTerminal = nil
        operation = nil; approvals = []; error = nil
        saveTranscript()
        await submit(next)
    }

    func retryOriginal() async {
        guard canRetry, let receipt else { return }
        await submit(receipt)
    }

    private func submit(_ receipt: WorkshopReceipt) async {
        guard scope == store.scope, !busy else { return }
        busy = true
        defer { busy = false; uploadProgress = nil }
        do {
            if let ids = receipt.imageIds, !ids.isEmpty {
                uploadProgress = 0
                try await store.uploadImages(ids, agent: agent) { uploadProgress = $0 }
            }
            let result: WorkshopOperation = try await store.call(agent, "turn.start", receipt.parameters)
            guard scope == store.scope, result.id == receipt.id else { throw CancellationError() }
            operation = result; uncertain = false; error = nil
            clearSentDraft(receipt.message, imageIds: receipt.imageIds ?? [], id: receipt.id)
            if let id = result.threadId {
                if threadId == nil { try store.saveChoice(choice, agent: agent, thread: id, application: application) }
                threadId = id
            }
            var accepted = receipt
            accepted.threadId = threadId
            accepted.state = result.active ? "pending" : result.state
            try store.saveReceipt(accepted)
            self.receipt = accepted
            try await poll(result.id)
        } catch is CancellationError { }
        catch let failure as WorkshopFailure where ["invalid_params", "codex_application_missing", "codex_workspace_invalid", "codex_busy", "codex_image_missing", "codex_image_invalid"].contains(failure.code) {
            guard scope == store.scope else { return }
            uncertain = false; operationId = nil; operation = nil
            var rejected = receipt; rejected.state = "rejected"
            self.receipt = rejected
            try? store.saveReceipt(rejected)
            if draftSendingID == receipt.id { draftSendingID = nil }
            if draft.isEmpty && photos.isEmpty { draft = receipt.message }
            error = failure.message
            saveTranscript()
        }
        catch { if scope == store.scope { self.error = "发送结果尚未确认。\(error.localizedDescription) 可以检查进度，或用原请求 ID 重试。" } }
    }

    func checkResult() async {
        await synchronize()
    }

    private func readFailed(_ failure: Error) {
        guard !Task.isCancelled, scope == store.scope else { return }
        lastVerifiedAt = nil
        let underlying = failure as NSError
        if failure is CancellationError || underlying.domain == NSURLErrorDomain || underlying.domain == NSPOSIXErrorDomain {
            connectionIssue = "与服务器的连接已中断，正在重新连接。电脑上的任务会继续执行。"
        } else { error = failure.localizedDescription }
    }

    func pendingSend(_ id: String) -> WorkshopQueuedSend? {
        guard let operationId else { return nil }
        return store.pendingQueue(operationId: operationId).first { $0.id == id }
    }

    func retryQueued(_ id: String) async {
        guard let queued = pendingSend(id), !busy else { return }
        await submitQueued(queued)
    }

    private func submitQueued(_ queued: WorkshopQueuedSend) async {
        guard scope == store.scope, !busy else { return }
        busy = true
        defer { busy = false; uploadProgress = nil }
        do {
            if !queued.imageIds.isEmpty {
                uploadProgress = 0
                try await store.uploadImages(queued.imageIds, agent: agent) { uploadProgress = $0 }
            }
            let result: WorkshopFollowupReply = try await store.call(agent, "message.queue", queued.parameters)
            guard scope == store.scope, operationId == queued.operationId, result.id == queued.id else { throw CancellationError() }
            acceptFollowup(result)
            clearSentDraft(queued.message, imageIds: queued.imageIds, id: queued.id)
            try store.saveQueuedSend(nil, removing: queued.id)
            observedTerminal = nil
            try await poll(queued.operationId)
        } catch is CancellationError { }
        catch let failure as WorkshopFailure where ["invalid_params", "codex_queue_full", "codex_image_missing", "codex_image_invalid"].contains(failure.code) {
            guard scope == store.scope else { return }
            store.rejectQueuedActivity(queued, agent: agent, scope: scope)
            if draftSendingID == queued.id {
                do {
                    try store.saveQueuedSend(nil, removing: queued.id)
                    entries.removeAll { $0.id == queued.id }
                    draftSendingID = nil
                    saveTranscript()
                } catch { self.error = "排队未成功，输入草稿已保留。\(error.localizedDescription)"; return }
            } else if draft.isEmpty && photos.isEmpty {
                do {
                    let restoredPhotos = try queued.imageIds.map { try store.savedPhoto($0) }
                    try store.saveQueuedSend(nil, removing: queued.id)
                    entries.removeAll { $0.id == queued.id }
                    draft = queued.message; photos = restoredPhotos
                    saveTranscript()
                } catch { self.error = "排队未成功，原消息已保留，可在检查后重试。\(error.localizedDescription)"; return }
            }
            self.error = failure.message
        }
        catch { if scope == store.scope { self.error = "排队结果尚未确认。\(error.localizedDescription) 可检查结果或重试这条原消息。" } }
    }

    private func acceptFollowup(_ result: WorkshopFollowupReply) {
        followups.removeAll { $0.id == result.id }; followups.append(result.status)
        apply(result.entry)
        saveTranscript()
    }

    func editMessage(_ entry: WorkshopEntry) {
        guard canEditMessages, let status = followups.first(where: { $0.id == entry.id }), status.editable else { return }
        if editingMessageID == nil { editingDraft = (draft, photos) }
        editingMessageID = entry.id
        let suffix = "\n[图片 × \(status.imageIds.count)]"
        draft = !status.imageIds.isEmpty && entry.text.hasSuffix(suffix) ? String(entry.text.dropLast(suffix.count)) : entry.text
        photos = []
    }

    func cancelEditing() {
        draft = editingDraft?.text ?? ""; photos = editingDraft?.photos ?? []
        editingMessageID = nil; editingDraft = nil
    }

    func mutateMessage(_ id: String, action: String, message: String? = nil) async {
        guard canEditMessages, let operationId, let status = followups.first(where: { $0.id == id }), status.editable else { return }
        busy = true
        defer { busy = false }
        var parameters: [String: Any] = ["operationId": operationId, "messageId": id,
            "requestId": UUID().uuidString.lowercased(), "revision": status.revision]
        parameters["message"] = message
        do {
            let result: WorkshopFollowupReply = try await store.call(agent, "message.\(action)", parameters)
            guard scope == store.scope, self.operationId == operationId else { throw CancellationError() }
            acceptFollowup(result)
            if editingMessageID == id { cancelEditing() }
            observedTerminal = nil; error = result.detail
            try await poll(operationId)
        } catch is CancellationError { }
        catch { if scope == store.scope { self.error = "操作结果尚未确认，请检查这条消息的状态。\(error.localizedDescription)" } }
    }

    func stop() async {
        guard let operationId, operation?.active == true, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let _: WorkshopOperation = try await store.call(agent, "turn.stop", ["operationId": operationId])
            try await poll(operationId)
        } catch { self.error = error.localizedDescription }
    }

    func reply(_ approval: WorkshopApproval, decision: String? = nil, answers: [String: String] = [:]) async {
        guard let operationId, !busy else { return }
        busy = true
        defer { busy = false }
        var params: [String: Any] = ["operationId": operationId, "approvalId": approval.id]
        params["decision"] = decision
        if !answers.isEmpty { params["answers"] = answers }
        do {
            let _: WorkshopOperation = try await store.call(agent, "approval.reply", params)
            try await poll(operationId)
        } catch { self.error = error.localizedDescription }
    }
}
