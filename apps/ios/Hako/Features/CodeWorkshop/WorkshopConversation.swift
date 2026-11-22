import Foundation
import Combine

@MainActor final class WorkshopConversation: ObservableObject, Identifiable {
    let id = UUID()
    let store: WorkshopStore
    let agent: WorkshopAgent
    let application: WorkshopApplication
    @Published private(set) var title: String
    let scope: String
    @Published private(set) var threadId: String? { didSet { persistDraft() } }
    @Published private(set) var isArchived: Bool
    private(set) var entries: [WorkshopEntry] = [] { didSet { schedulePresentation() } }
    @Published private(set) var presentation = WorkshopTranscriptLayout()
    @Published private(set) var restoringCache = false
    @Published private(set) var artifacts: [WorkshopArtifact] = [] { didSet { schedulePresentation() } }
    @Published private(set) var operation: WorkshopOperation?
    @Published private(set) var approvals: [WorkshopApproval] = []
    @Published private(set) var historyCursor: String?
    @Published private(set) var busy = false
    @Published private(set) var access: WorkshopThreadAccess?
    @Published private(set) var checkingAccess = false
    @Published private(set) var loadingHistory = false
    @Published private(set) var uncertain = false
    let composerInput = WorkshopComposerInput()
    var draft: String {
        get { composerInput.text }
        set { composerInput.text = newValue }
    }
    @Published var error: String?
    @Published private(set) var connectionIssue: String?
    private var syncFailureStarted: Date?
    private var syncFailureCount = 0
    private var lastSyncFailureCode: String?
    private var lastSyncFailureLog: Date?
    @Published private(set) var photos: [WorkshopPhoto] = [] { didSet { composerChanged() } }
    @Published private(set) var outbox = WorkshopOutbox()
    private var imageUpload: Task<Void, Error>?
    private var cancelledUploadID: String?
    @Published private(set) var models: [WorkshopModel] = []
    @Published private(set) var loadingModels = false
    @Published private(set) var modelError: String?
    @Published private(set) var choice = WorkshopChoice()
    @Published private(set) var historyGeneration = WorkshopGenerationSettings()
    @Published private(set) var followups: [WorkshopFollowupState] = [] { didSet { schedulePresentation() } }
    @Published private(set) var editingMessageID: String? { didSet { persistDraft() } }
    @Published private(set) var appendedMessageID: String?
    @Published private(set) var cachedAt: Date?
    @Published private(set) var synchronizing = false
    private var editingDraft: (text: String, photos: [WorkshopPhoto])? { didSet { persistDraft() } }
    private var draftReady = false
    private var resettingComposer = false
    private var composerAcknowledgements: Set<String> = []
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
    @Published private var hasVerifiedSync = false
    private var lastVerifiedAt: Date? {
        didSet {
            if hasVerifiedSync != (lastVerifiedAt != nil) { hasVerifiedSync = lastVerifiedAt != nil }
        }
    }
    private var historyCursorVerified = false
    var networkVisible = false {
        didSet {
            if networkVisible && !oldValue {
                schedulePresentation()
                Task { await refreshThreadAccess() }
            }
        }
    }
    private var catalogHint: WorkshopSession?
    private var needsHistoryRefresh = false
    var connectionVerified: Bool {
        hasVerifiedSync || (threadId == nil && !models.isEmpty && modelError == nil)
    }
    var needsConnectionRecovery: Bool {
        connectionIssue != nil || uncertain || operation?.resultUnconfirmed == true
    }
    var presentedError: String? {
        if let operation { return operation.errorCardMessage(error) }
        return error
    }
    var synchronizationHint: String? {
        if !threadWritable {
            if let access {
                if let warning = access.synchronizationWarning(operation: operation, threadId: threadId) { return warning }
            } else {
                return "正在检查会话是否可写，可先编辑草稿"
            }
        }
        if connectionIssue != nil { return "会话暂未同步，自动重试中" }
        if operation?.resultUnconfirmed == true { return "本轮结果待确认" }
        return nil
    }
    private var cacheLoad: Task<WorkshopTranscript?, Never>?
    private let renderer = WorkshopTranscriptRenderer()
    private var presentationTask: Task<Void, Never>?
    private var presentationRevision = 0

    init(store: WorkshopStore, agent: WorkshopAgent, application: WorkshopApplication, session: WorkshopSession? = nil, title: String? = nil, archived: Bool = false) {
        self.store = store; self.agent = agent; self.application = application
        self.title = title ?? session?.title ?? "新会话"
        scope = store.scope
        catalogHint = session
        access = session?.access
        isArchived = archived
        threadId = session.flatMap { UUID(uuidString: $0.id) == nil ? nil : $0.id }
        receipt = store.receipt(for: session, agent: agent)
        operationId = session?.operationId ?? receipt?.id
        if let receipt, receipt.id == operationId, receipt.state == "pending" {
            uncertain = true; entries.append(receipt.entry); outbox.restore(receipt.id)
        }
        choice = store.choice(agent: agent, thread: threadId, application: application)
        if let operationId {
            for pending in store.pendingQueue(operationId: operationId) where !entries.contains(where: { $0.id == pending.id }) {
                entries.append(pending.entry); outbox.restore(pending.id)
            }
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
        composerInput.onChange = { [weak self] in self?.composerChanged() }
        if savedDraft != nil { persistDraft() }
        if let threadId {
            restoringCache = true
            let key = WorkshopTranscriptKey(agentId: agent.id, applicationId: application.id, threadId: threadId)
            cacheLoad = Task { await store.cachedTranscript(key) }
        }
        schedulePresentation()
    }

    private func restoreTranscript() async {
        guard let load = cacheLoad else { return }
        let snapshot = await load.value
        guard !Task.isCancelled, scope == store.scope, cacheLoad != nil else { return }
        cacheLoad = nil
        if let snapshot {
            let pending = entries
            entries = snapshot.entries
            for entry in pending where !entries.contains(where: { $0.id == entry.id }) { entries.append(entry) }
            artifacts = snapshot.artifacts; followups = snapshot.followups
            historyCursor = snapshot.historyCursor; cachedAt = snapshot.savedAt
            if operationId == nil { operationId = snapshot.operationId }
            if operationId == snapshot.operationId { eventCursor = snapshot.eventCursor; streamText = snapshot.streamText }
            savedTranscript = snapshot
            uncertain = operationId != nil
        }
        restoringCache = false
    }

    private func schedulePresentation() {
        presentationRevision += 1
        guard networkVisible, presentationTask == nil else { return }
        presentationTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { break }
                guard let self, self.networkVisible, self.scope == self.store.scope else { break }
                let revision = self.presentationRevision
                let layout = await self.renderer.render(entries: self.entries, followups: self.followups,
                    artifacts: self.artifacts, projectPath: self.application.path, revision: revision)
                guard !Task.isCancelled, self.networkVisible, self.scope == self.store.scope else { break }
                self.presentation = layout
                if revision == self.presentationRevision { break }
            }
            self?.presentationTask = nil
        }
    }

    private var composerSessionID: String { threadId ?? operationId.map { "pending-" + $0 } ?? "new:" + title }

    private var composerDraft: WorkshopComposerDraft {
        WorkshopComposerDraft(input: WorkshopDraftInput(text: draft, imageIds: photos.map(\.id)),
            editingMessageID: editingMessageID,
            originalInput: editingDraft.map { WorkshopDraftInput(text: $0.text, imageIds: $0.photos.map(\.id)) },
            sendingMessageID: draftSendingID)
    }

    private func persistDraft() {
        guard draftReady, !resettingComposer, scope == store.scope else { return }
        let snapshot = composerDraft
        let sessionID = composerSessionID
        guard snapshot != savedDraft || sessionID != draftSessionID else { return }
        do {
            try store.saveComposerDraft(snapshot, agent: agent, application: application, sessionId: sessionID,
                previousSessionId: draftSessionID, scope: scope) { [weak self] error in
                    guard let self, self.savedDraft == snapshot, self.draftSessionID == sessionID else { return }
                    self.savedDraft = nil
                    self.error = "输入尚在本页，但草稿保存失败，请勿退出。\(error.localizedDescription)"
                }
            draftSessionID = sessionID; savedDraft = snapshot
        } catch { self.error = "输入尚在本页，但草稿保存失败，请勿退出。\(error.localizedDescription)" }
    }

    private func composerChanged() {
        guard !resettingComposer else { return }
        if draftReady { draftSendingID = nil }
        persistDraft()
    }

    private func clearSentDraft(_ message: String, imageIds: [String], id: String) {
        let snapshot = composerDraft
        let matches = snapshot.matchesSentMessage(message, imageIds: imageIds, id: id)
        if composerAcknowledgements.insert(id).inserted {
            HakoLog.record(.codeWorkshop, "发送记录持久化后核验输入草稿",
                detail: "requestId=\(id); imageCount=\(imageIds.count); requestMatches=\(snapshot.sendingMessageID == id); textMatches=\(snapshot.input.text.trimmingCharacters(in: .whitespacesAndNewlines) == message); imagesMatch=\(snapshot.input.imageIds == imageIds); willClear=\(matches)")
        }
        guard matches else { return }
        // Text and attachments have separate observation callbacks. Persist
        // only their final empty value, never an intermediate partial draft.
        resettingComposer = true
        composerInput.clearAfterSending(); photos = []
        draftSendingID = nil
        resettingComposer = false
        persistDraft()
        HakoLog.record(.codeWorkshop, "消息已交给发送记录并清空输入草稿",
            detail: "requestId=\(id); imageCount=\(imageIds.count); editorId=\(composerInput.editorID); textLength=\(draft.utf16.count); remainingImages=\(photos.count)")
    }

    var notificationOperationID: String? { operationId }

    private func observeAccess(_ value: WorkshopThreadAccess?) {
        guard let value, value.checkedAt >= (access?.checkedAt ?? 0) else { return }
        access = value
    }

    private func verifyThreadAccess() async -> Bool {
        guard let threadId else { return true }
        guard !checkingAccess, scope == store.scope else { return false }
        checkingAccess = true
        defer { checkingAccess = false }
        do {
            let current: WorkshopThreadAccess = try await store.call(agent, "thread.access.read",
                ["threadId": threadId, "applicationId": application.id])
            guard scope == store.scope, self.threadId == threadId else { return false }
            access = current
            if let reason = current.unavailableReason { error = reason }
            return current.canSend
        } catch {
            guard scope == store.scope else { return false }
            access = WorkshopThreadAccess(state: "unknown", checkedAt: access?.checkedAt ?? 0)
            self.error = "无法确认会话是否可写，文字和图片已保留。" + error.localizedDescription
            return false
        }
    }

    private func requireThreadAccess() async throws {
        guard await verifyThreadAccess() else {
            throw WorkshopFailure(code: access?.state == "occupied" ? "codex_thread_occupied" : "codex_thread_access_unknown",
                message: error ?? "会话暂不可写，文字和图片已保留。")
        }
    }

    private func watchAccess() async {
        while !Task.isCancelled, scope == store.scope {
            await refreshThreadAccess()
            do { try await Task.sleep(for: .seconds(networkVisible ? 10 : 60)) } catch { return }
        }
    }

    private func refreshThreadAccess() async {
        guard let threadId, !checkingAccess, scope == store.scope else { return }
        do {
            let value: WorkshopThreadAccess = try await store.call(agent, "thread.access.read",
                ["threadId": threadId, "applicationId": application.id])
            guard !Task.isCancelled, scope == store.scope, self.threadId == threadId else { return }
            observeAccess(value)
        } catch {
            guard !Task.isCancelled, scope == store.scope else { return }
            access = WorkshopThreadAccess(state: "unknown", checkedAt: access?.checkedAt ?? 0)
        }
    }

    private func accessRejected(_ failure: WorkshopFailure) {
        guard ["codex_thread_occupied", "codex_thread_access_unknown"].contains(failure.code) else { return }
        access = WorkshopThreadAccess(state: failure.code == "codex_thread_occupied" ? "occupied" : "unknown",
            checkedAt: access?.checkedAt ?? 0)
    }

    var canCompose: Bool { !isArchived && (!busy || outbox.activeID != nil) && store.authenticated && scope == store.scope }
    var configurationUnavailableReason: String? {
        if isArchived { return "此会话已归档，取消归档后可修改设置。" }
        if !store.authenticated { return "请先在 Hako 设置中登录服务器后修改会话设置。" }
        if scope != store.scope { return "登录身份已变化，请返回会话列表后重新打开此会话。" }
        return nil
    }
    var canConfigure: Bool { configurationUnavailableReason == nil }
    var awaitingSubmissionCheck: Bool { restoringCache || synchronizing || (uncertain && outbox.activeID == nil) }
    private var threadWritable: Bool { threadId == nil || (access?.canSend ?? (operation?.active == true)) }
    var canSubmitMessage: Bool { canCompose && !awaitingSubmissionCheck && !checkingAccess && threadWritable }
    var canEditMessages: Bool { canSubmitMessage && !busy && !hasMoreEvents }
    var hasDraftInput: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !photos.isEmpty ||
        (editingMessageID != nil && followups.contains { $0.id == editingMessageID && !$0.imageIds.isEmpty }) }
    var canRetry: Bool { threadWritable && !isArchived && !restoringCache && uncertain && receipt?.id == operationId && receipt?.state == "pending" && !busy && !synchronizing && operation?.active != true }
    var generation: WorkshopGenerationSettings { .displayed(history: historyGeneration, operation: operation) }
    var modelLabel: String { models.first { $0.id == generation.model }?.name ?? generation.model ?? "Model pending" }
    var speedLabel: String {
        let tier = choice.serviceTier ?? WorkshopSpeed.standard.id
        if tier == WorkshopSpeed.standard.id { return WorkshopSpeed.standard.name }
        let modelID = choice.model ?? generation.model
        let selectedModel = models.first { $0.id == modelID } ?? (modelID == nil ? models.first { $0.isDefault } : nil)
        return selectedModel?.serviceTiers.first { $0.id == tier }?.name ?? tier
    }
    var generationLabel: String { modelLabel + " · " + speedLabel + " · " + generation.effortLabel }

    var reuseKey: WorkshopConversationReuseKey? {
        guard let sessionId = threadId ?? operationId.map({ "pending-" + $0 }) else { return nil }
        return WorkshopConversationReuseKey(scope: scope, agentId: agent.id, applicationId: application.id,
            sessionId: sessionId, archived: isArchived)
    }

    func prepareForReentry(_ session: WorkshopSession) {
        observeAccess(session.access)
        if WorkshopWatchStep.catalogNeedsSynchronization(previous: catalogHint, current: session,
            operationId: operationId, operationActive: operation?.active == true, completionId: latestCompletionID) {
            lastVerifiedAt = nil
            needsHistoryRefresh = true
            eventStream?.cancel()
        }
        catalogHint = session
    }

    var canCompact: Bool {
        canConfigure && threadWritable && !busy && !awaitingSubmissionCheck && !loadingHistory && threadId != nil &&
            operation?.active != true && !followups.contains { $0.editable || $0.state == "paused" } &&
            operationId.map { store.pendingQueue(operationId: $0).isEmpty } != false
    }

    func rename(_ name: String) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canConfigure, !busy, !name.isEmpty, name.utf16.count <= 120,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw HakoError(message: "会话名称需为 1–120 个字符。")
        }
        guard name != title else { return }
        busy = true
        defer { busy = false }
        if let threadId {
            struct Reply: Decodable { let threadId: String; let name: String }
            let reply: Reply = try await store.call(agent, "thread.rename", ["threadId": threadId, "applicationId": application.id, "name": name])
            guard scope == store.scope, reply.threadId == threadId, reply.name == name else { throw CancellationError() }
            store.renameSession(threadId, agentID: agent.id, title: name)
        }
        title = name
        persistDraft()
    }

    func compactContext() async {
        guard canCompact, let threadId else { return }
        let id = UUID().uuidString.lowercased()
        busy = true; error = nil
        defer { busy = false }
        operationId = id; operation = nil; eventCursor = 0; streamText = [:]; observedTerminal = nil
        uncertain = true
        saveTranscript()
        do {
            let result: WorkshopOperation = try await store.call(agent, "thread.compact", ["threadId": threadId,
                "applicationId": application.id, "requestId": id, "permission": choice.permission.rawValue])
            guard scope == store.scope, result.id == id else { throw CancellationError() }
            operation = result; uncertain = false
        } catch let failure as WorkshopFailure where ["invalid_params", "unsupported_method", "codex_busy", "codex_workspace_invalid"].contains(failure.code) {
            if scope == store.scope { operationId = nil; uncertain = false; error = failure.message }
        } catch {
            if scope == store.scope { self.error = "压缩请求结果待确认，请检查任务状态。" }
        }
        saveTranscript()
    }

    func loadModels() async {
        guard !loadingModels else { return }
        loadingModels = true; modelError = nil
        defer { loadingModels = false }
        do {
            let result: WorkshopModelList = try await store.call(agent, "models.list")
            guard scope == store.scope else { return }
            guard !result.models.isEmpty else { throw HakoError(message: "执行电脑未返回可用模型，请检查电脑上的模型配置后重试。") }
            models = result.models
        } catch is CancellationError {
            if models.isEmpty && scope == store.scope { modelError = "模型读取已中断，请重新读取。" }
        }
        catch { modelError = error.localizedDescription }
    }

    func configure(_ next: WorkshopChoice) throws {
        if let reason = configurationUnavailableReason { throw HakoError(message: reason) }
        let modelID = next.model ?? generation.model
        let selected = models.first { $0.id == modelID } ?? (modelID == nil ? models.first { $0.isDefault } : nil)
        if let tier = next.serviceTier, tier != "default", selected?.serviceTiers.contains(where: { $0.id == tier }) != true {
            throw HakoError(message: "所选模型暂不支持此速度，请刷新模型列表后重新选择。")
        }
        if let effort = next.reasoningEffort, selected?.reasoningEfforts.contains(where: { $0.id == effort }) != true {
            throw HakoError(message: "所选模型暂不支持此推理强度，请刷新模型列表后重新选择。")
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
        await restoreTranscript()
        guard !Task.isCancelled, let threadId, !loadingHistory, scope == store.scope else { return false }
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
            if !more { historyGeneration = result.generation; observeAccess(result.access) }
            let newestOperation = result.operationId
            let newestCompletion = result.completionId
            var newestArtifacts = result.artifacts
            let newestCursor = result.nextCursor
            var page = result.entries
            var pages = 1
            // Fill a gap since the cached tail, or skip older pages already in the cache.
            while let cursor = result.nextCursor, pages < 32,
                  more ? result.entries.allSatisfy({ existingIDs.contains($0.id) }) :
                    (page.isEmpty || (!existingIDs.isEmpty && !page.contains(where: { existingIDs.contains($0.id) }))) {
                try Task.checkCancellation()
                let next: WorkshopHistory = try await store.call(agent, "history.read", ["threadId": threadId, "cursor": cursor])
                guard scope == store.scope, next.threadId == threadId, next.nextCursor != cursor else { break }
                result = next; page = next.entries + page; pages += 1
                newestArtifacts += next.artifacts.filter { artifact in !newestArtifacts.contains(where: { $0.id == artifact.id }) }
            }
            guard scope == store.scope else { return false }
            entries = WorkshopTranscriptMerge.history(entries, page: page)
            if more {
                historyCursor = result.nextCursor
            } else {
                let overlaps = page.contains { existingIDs.contains($0.id) }
                historyCursor = historyCursorVerified && overlaps && previousCursor != nil ? previousCursor : newestCursor
                historyCursorVerified = true
            }
            for artifact in newestArtifacts where !artifacts.contains(where: { $0.id == artifact.id }) { artifacts.append(artifact) }
            cachedAt = nil
            // A successful history read alone does not verify the operation
            // connection. Keep the failure visible until both reads succeed.
            if !synchronizing, operationId == nil { clearConnectionIssue(); error = nil }
            if !more, operation?.state == "unknown" { observedTerminal = nil }
            if !more {
                latestCompletionID = newestCompletion; markLatestRead()
                if let newestCompletion, newestOperation == nil ||
                    (!uncertain && operation?.active == false && operationId == newestOperation && observedTerminal == operationId) {
                    store.observeSession(threadId: threadId, operationId: newestOperation, state: "completed",
                        completionId: newestCompletion, agent: agent, scope: scope)
                }
            }
            if !more, operationId == originalOperation, let newestOperation, newestOperation != operationId,
               !(receipt?.id == operationId && receipt?.state == "pending") {
                operationId = newestOperation; operation = nil; eventCursor = 0; streamText = [:]
                observedTerminal = nil; uncertain = true; followups = []
                if receipt?.id != newestOperation { receipt = nil }
            }
            if !more, operationId == nil {
                operationId = newestOperation
                if let operationId {
                    for pending in store.pendingQueue(operationId: operationId) where !entries.contains(where: { $0.id == pending.id }) {
                        entries.append(pending.entry)
                        if outbox.states[pending.id] == nil { outbox.restore(pending.id) }
                    }
                }
            }
            if !more, !uncertain, operationId == nil || observedTerminal == operationId { lastVerifiedAt = .now }
            saveTranscript()
            return true
        } catch { readFailed(error); return false }
    }

    func watch() async {
        let accessWatch = Task { await watchAccess() }
        defer { accessWatch.cancel() }
        await restoreTranscript()
        guard !Task.isCancelled, scope == store.scope else { return }
        let entryStep = WorkshopWatchStep.onEntry(lastVerifiedAt: lastVerifiedAt,
            operationId: operationId, observedTerminal: observedTerminal,
            needsRecovery: needsHistoryRefresh || connectionIssue != nil || uncertain, busy: busy || synchronizing || outbox.holdsOperation(operationId))
        if entryStep == .synchronize { await synchronize() }
        // A completed/external conversation only needs its latest history page;
        // keep the verified composer usable while checking for changes.
        else if entryStep == .idle, !busy, !synchronizing, !outbox.holdsOperation(operationId), threadId != nil { await loadHistory() }
        var failures = 0
        var idleChecks = 0
        while !Task.isCancelled, scope == store.scope {
            switch WorkshopWatchStep.next(operationId: operationId, observedTerminal: observedTerminal,
                needsRecovery: needsHistoryRefresh || connectionIssue != nil || uncertain, busy: busy || synchronizing || outbox.holdsOperation(operationId)) {
            case .synchronize:
                idleChecks = 0
                await synchronize()
                failures = connectionIssue == nil && !uncertain ? 0 : failures + 1
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
                if !busy && !synchronizing && !outbox.holdsOperation(operationId) {
                    idleChecks += 1
                    if idleChecks >= (networkVisible ? 10 : 60) {
                        idleChecks = 0
                        if threadId != nil { await loadHistory() }
                        else { await loadModels() }
                    }
                }
            }
            do { try await Task.sleep(for: .milliseconds(WorkshopWatchStep.delayMilliseconds(hasMoreEvents: hasMoreEvents, failures: failures))) }
            catch { return }
        }
    }

    func synchronize() async {
        await restoreTranscript()
        guard !Task.isCancelled, !synchronizing, !outbox.holdsOperation(operationId), scope == store.scope else { return }
        synchronizing = true
        defer { synchronizing = false; resumePendingSends() }
        if let stream = eventStream {
            stream.cancel()
            _ = try? await stream.value
            eventStream = nil
        }
        if operationId != nil { uncertain = true }
        // Reconcile the known operation while history is in flight. A slow
        // transcript must not delay a terminal state or an approval response.
        let previousOperation = operationId
        let history = Task { await self.loadHistory() }
        defer { history.cancel() }
        if let previousOperation {
            do { try await poll(previousOperation) }
            catch { readFailed(error) }
        }
        let loadedHistory = await withTaskCancellationHandler { await history.value } onCancel: { history.cancel() }
        guard !Task.isCancelled, scope == store.scope else { return }
        // A slow history read must not prevent the independent task-state
        // check from discovering that the computer has already finished.
        if let operationId {
            do {
                if operationId != previousOperation { try await poll(operationId) }
                needsHistoryRefresh = !loadedHistory
            }
            catch { readFailed(error) }
        } else {
            needsHistoryRefresh = false
            // External conversations have no operation stream to confirm recovery.
            // A successful history read is their complete connection check.
            if loadedHistory { clearConnectionIssue() }
        }
    }

    private func saveTranscript() {
        guard !restoringCache, let threadId, scope == store.scope else { return }
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
        if operation != result.operation { operation = result.operation }
        if result.operation.active, error != nil { error = nil }
        if connectionIssue != nil { clearConnectionIssue() }
        if uncertain { uncertain = false }
        if cachedAt != nil { cachedAt = nil }
        let nextFollowups = WorkshopFollowupState.merging(result.followups, into: followups)
        if followups != nextFollowups { followups = nextFollowups }
        if let receipt, receipt.id == id {
            outbox.acknowledge(id)
            clearSentDraft(receipt.message, imageIds: receipt.imageIds ?? [], id: id)
        }
        var nextEntries = entries
        if result.cursor > eventCursor { WorkshopTranscriptMerge.apply(result.events, entries: &nextEntries, streamText: &streamText) }
        for followup in followups {
            outbox.acknowledge(followup.id)
            if let queued = pendingSend(followup.id) { clearSentDraft(queued.message, imageIds: queued.imageIds, id: queued.id) }
            try store.saveQueuedSend(nil, removing: followup.id, background: true)
            if followup.state == "cancelled" { nextEntries.removeAll { $0.id == followup.id }; continue }
            if let index = nextEntries.firstIndex(where: { $0.id == followup.id && $0.kind == "followup" && $0.state != followup.state }) {
                let entry = nextEntries[index]
                nextEntries[index] = WorkshopEntry(kind: entry.kind, id: entry.id, text: entry.text, role: entry.role,
                    state: followup.state, truncated: entry.truncated, questionId: entry.questionId)
            }
        }
        if entries != nextEntries { entries = nextEntries }
        hasMoreEvents = result.hasMore && result.cursor > eventCursor
        eventCursor = result.cursor
        if approvals != result.approvals { approvals = result.approvals }
        for artifact in result.artifacts where !artifacts.contains(where: { $0.id == artifact.id }) { artifacts.append(artifact) }
        if let resolved = result.operation.threadId, resolved != threadId {
            if threadId == nil { try store.saveChoice(choice, agent: agent, thread: resolved, application: application, background: true) }
            threadId = resolved
        }
        if var receipt, receipt.id == id {
            receipt.threadId = threadId
            receipt.state = result.operation.active ? "pending" : result.operation.state
            try store.saveReceipt(receipt, background: true)
            self.receipt = receipt
        }
        saveTranscript()
        lastVerifiedAt = .now
        if let threadId, result.operation.state != "completed" ||
            (result.operation.turnId != nil && latestCompletionID == result.operation.turnId) {
            store.observeSession(threadId: threadId, operationId: id, state: result.operation.state,
                completionId: result.hasMore ? nil : result.operation.turnId, agent: agent, scope: scope)
        }
        if !result.operation.active && !result.hasMore {
            observedTerminal = id
            if result.operation.state == "completed" { latestCompletionID = result.operation.turnId; markLatestRead() }
            error = result.operation.message.flatMap { $0.isEmpty ? nil : $0 }
            entries = WorkshopTranscriptMerge.withoutRecoveredNotices(entries, operationId: id,
                state: result.operation.state, followups: followups)
            saveTranscript()
            if result.operation.state == "completed" || result.operation.state == "interrupted" { await loadHistory() }
            await store.refresh()
        }
        resumePendingSends()
    }

    private func apply(_ event: WorkshopEntry) {
        WorkshopTranscriptMerge.apply(event, entries: &entries, streamText: &streamText)
    }

    func send() async { await sendInput(prompt: nil) }

    var canSendPrompt: Bool { canSubmitMessage && editingMessageID == nil && draftSendingID == nil }
    func sendPrompt(_ text: String) async {
        guard canSendPrompt else { return }
        await sendInput(prompt: text)
    }

    private func sendInput(prompt: String?) async {
        let message = (prompt ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = prompt == nil ? photos : []
        guard canSubmitMessage, prompt == nil ? hasDraftInput : !message.isEmpty else { return }
        guard message.utf16.count <= 4000 else { error = "消息最多 4,000 个字符，请分段发送。"; return }
        if let id = editingMessageID {
            await mutateMessage(id, action: "update", message: message)
            return
        }
        guard await verifyThreadAccess() else { return }
        if let id = draftSendingID, let queued = pendingSend(id) {
            await submitQueued(queued)
            return
        }
        if !attachments.isEmpty, let model = models.first(where: { $0.id == choice.model }), !model.supportsImages {
            error = "当前模型不支持图片，请在更多页面选择支持图片的模型。"; return
        }
        if let operationId, outbox.activeID != nil || operation?.active == true || followups.contains(where: { $0.editable }) ||
            !store.pendingQueue(operationId: operationId).isEmpty {
            let resume = operation?.active != true
            let queued = WorkshopQueuedSend(id: UUID().uuidString.lowercased(), operationId: operationId,
                message: message, imageIds: attachments.map(\.id), reasoningEffort: choice.reasoningEffort)
            do { try store.saveQueuedSend(queued) }
            catch { self.error = "无法保存排队消息，请重试。"; return }
            store.recordQueuedActivity(queued, agent: agent, application: application, threadId: threadId, title: title, scope: scope)
            if prompt == nil { draftSendingID = queued.id }
            entries.append(queued.entry); appendedMessageID = queued.id; error = nil
            outbox.enqueue(queued.id)
            clearSentDraft(queued.message, imageIds: queued.imageIds, id: queued.id)
            saveTranscript()
            await store.flushComposerDrafts()
            await submitQueued(queued)
            if resume, followups.contains(where: { $0.id == queued.id && $0.editable }) {
                await mutateMessage(queued.id, action: "steer")
            }
            return
        }
        if threadId == nil, let issue = store.systemPromptLoadError { error = issue; return }
        let next = WorkshopReceipt(id: UUID().uuidString.lowercased(), agentId: agent.id, applicationId: application.id,
            originalThreadId: threadId, threadId: threadId, title: title, message: message, createdAt: .now, state: "pending",
            model: choice.model, permission: choice.permission.rawValue, imageIds: attachments.isEmpty ? nil : attachments.map(\.id),
            serviceTier: choice.serviceTier ?? "default", systemPrompt: threadId == nil ? store.systemPrompt : nil,
            reasoningEffort: choice.reasoningEffort)
        guard next.fitsRequestBudget else { error = "首条消息与系统提示词合计过长，请缩短提示词或消息内容。"; return }
        do { try store.saveReceipt(next) }
        catch { self.error = "无法保存发送记录，请重试。"; return }
        if prompt == nil { draftSendingID = next.id }
        receipt = next; uncertain = true; operationId = next.id; eventCursor = 0; streamText = [:]; observedTerminal = nil
        operation = nil; approvals = []; error = nil
        entries.append(next.entry); appendedMessageID = next.id; outbox.enqueue(next.id)
        clearSentDraft(next.message, imageIds: next.imageIds ?? [], id: next.id)
        saveTranscript()
        await store.flushComposerDrafts()
        await submit(next)
    }

    func hasAnswered(_ entry: WorkshopEntry) -> Bool {
        entries.contains { $0.role == "user" && $0.questionId == entry.id && $0.state != "cancelled" }
    }

    func replyToQuestion(_ entry: WorkshopEntry, answers: [Int: String]) async {
        guard canEditMessages, !hasAnswered(entry), let questions = entry.questions,
              let message = WorkshopAsyncQuestion.replyMessage(questions, answers: answers) else { return }
        let requestID = UUID().uuidString.lowercased()
        if let operationId {
            let queued = WorkshopQueuedSend(id: requestID, operationId: operationId, message: message,
                imageIds: [], questionId: entry.id, reasoningEffort: choice.reasoningEffort)
            do { try store.saveQueuedSend(queued) }
            catch { self.error = "无法保存回答，请重试。"; return }
            entries.append(queued.entry); appendedMessageID = queued.id; outbox.enqueue(queued.id); saveTranscript()
            store.recordQueuedActivity(queued, agent: agent, application: application, threadId: threadId, title: title, scope: scope)
            await submitQueued(queued)
            if followups.contains(where: { $0.id == queued.id && $0.editable }) {
                await mutateMessage(queued.id, action: "steer")
            }
        } else {
            if threadId == nil, let issue = store.systemPromptLoadError { error = issue; return }
            let next = WorkshopReceipt(id: requestID, agentId: agent.id, applicationId: application.id,
                originalThreadId: threadId, threadId: threadId, title: title, message: message, createdAt: .now,
                state: "pending", model: choice.model, permission: choice.permission.rawValue,
                serviceTier: choice.serviceTier ?? "default", questionId: entry.id,
                systemPrompt: threadId == nil ? store.systemPrompt : nil, reasoningEffort: choice.reasoningEffort)
            guard next.fitsRequestBudget else { error = "首条消息与系统提示词合计过长，请缩短提示词或消息内容。"; return }
            do { try store.saveReceipt(next) }
            catch { self.error = "无法保存回答，请重试。"; return }
            receipt = next; uncertain = true; operationId = next.id; operation = nil
            eventCursor = 0; streamText = [:]; observedTerminal = nil
            entries.append(next.entry); appendedMessageID = next.id; outbox.enqueue(next.id)
            saveTranscript()
            await submit(next)
        }
    }

    func retryOriginal() async {
        guard canRetry, let receipt else { return }
        await submit(receipt)
    }

    func canRetryDelivery(_ id: String) -> Bool {
        guard threadWritable, !busy, scope == store.scope, !isArchived else { return false }
        if receipt?.id == id { return canRetry }
        guard !uncertain, let operationId else { return false }
        return store.pendingQueue(operationId: operationId).first?.id == id
    }

    func retryDelivery(_ id: String) async {
        guard canRetryDelivery(id) else { return }
        if receipt?.id == id { await retryOriginal() }
        else { await retryQueued(id) }
    }

    func cancelUpload(_ id: String) {
        guard outbox.activeID == id, case .uploading = outbox.states[id] else { return }
        cancelledUploadID = id; imageUpload?.cancel()
    }

    private func uploadMessageImages(_ ids: [String], id: String) async throws {
        guard !ids.isEmpty else { return }
        let task = Task { try await store.uploadImages(ids, agent: agent) { outbox.progress($0, id: id) } }
        imageUpload = task
        do { try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() } }
        catch {
            if cancelledUploadID == id { throw CancellationError() }
            throw error
        }
        if cancelledUploadID == id { throw CancellationError() }
        try Task.checkCancellation()
    }

    private func resumePendingSends() {
        guard threadWritable, !busy, !synchronizing, !uncertain, scope == store.scope, let operationId,
              let id = outbox.nextQueued(store.pendingQueue(operationId: operationId).map(\.id)),
              let queued = pendingSend(id) else { return }
        Task { await submitQueued(queued) }
    }

    private func submit(_ receipt: WorkshopReceipt) async {
        guard scope == store.scope, !busy else { return }
        busy = true; error = nil; cancelledUploadID = nil
        outbox.begin(receipt.id, images: !(receipt.imageIds ?? []).isEmpty)
        var submitted = false, accepted = false
        defer {
            busy = false; imageUpload = nil; outbox.finish(receipt.id)
            resumePendingSends()
        }
        do {
            try await requireThreadAccess()
            try await uploadMessageImages(receipt.imageIds ?? [], id: receipt.id)
            guard scope == store.scope else { throw CancellationError() }
            outbox.sending(receipt.id); submitted = true
            let result: WorkshopOperation = try await store.call(agent, "turn.start", receipt.parameters)
            guard scope == store.scope, result.id == receipt.id else { throw CancellationError() }
            accepted = true; outbox.acknowledge(receipt.id)
            operation = result; uncertain = false; error = nil
            clearSentDraft(receipt.message, imageIds: receipt.imageIds ?? [], id: receipt.id)
            if let id = result.threadId {
                if threadId == nil { try store.saveChoice(choice, agent: agent, thread: id, application: application) }
                threadId = id
            }
            var confirmed = receipt
            confirmed.threadId = threadId
            confirmed.state = result.active ? "pending" : result.state
            try store.saveReceipt(confirmed)
            self.receipt = confirmed
            try await poll(result.id)
        } catch is CancellationError {
            if !accepted, outbox.states[receipt.id] != nil, scope == store.scope {
                outbox.failed(receipt.id, message: submitted ? "发送结果待确认，请检查结果或重试原消息。" : "上传已取消，文字和图片已保留。", submitted: submitted)
            }
        }
        catch let failure as WorkshopFailure where ["invalid_params", "codex_application_missing", "codex_workspace_invalid", "codex_busy", "codex_image_missing", "codex_image_invalid", "codex_thread_occupied", "codex_thread_access_unknown"].contains(failure.code) {
            guard scope == store.scope else { return }
            if accepted || outbox.states[receipt.id] == nil { readFailed(failure); return }
            accessRejected(failure)
            outbox.failed(receipt.id, message: failure.message, submitted: false)
            saveTranscript()
        }
        catch {
            guard scope == store.scope else { return }
            if accepted || outbox.states[receipt.id] == nil { readFailed(error) }
            else { outbox.failed(receipt.id, message: (submitted ? "发送结果尚未确认。" : "图片上传失败。") + error.localizedDescription, submitted: submitted) }
        }
    }

    func checkResult() async {
        await synchronize()
    }

    private func readFailed(_ failure: Error) {
        guard !Task.isCancelled, scope == store.scope else { return }
        lastVerifiedAt = nil
        hasMoreEvents = false
        if failure is CancellationError { return }
        syncFailureStarted = syncFailureStarted ?? .now
        syncFailureCount += 1
        let code = WorkshopSocketDiagnostics.error(failure)
        if code != lastSyncFailureCode || (lastSyncFailureLog.map({ Date.now.timeIntervalSince($0) >= 30 }) ?? true) {
            HakoLog.record(.codeWorkshop, .warning, "会话同步失败", detail:
                "operation=\(operationId ?? "none"); cursor=\(eventCursor); error=\(code); failures=\(syncFailureCount)")
            lastSyncFailureCode = code
            lastSyncFailureLog = .now
            store.recordDiagnostic("sync_failed", detail: "operation=\(operationId ?? "none"); cursor=\(eventCursor); error=\(code); failures=\(syncFailureCount)")
        }
        if WorkshopReadIssue.suppressesErrorCard(for: failure) {
            // The uncertain message already owns its check/retry controls.
            // A missing receipt is not proof that the original send failed.
            error = nil
        } else if let message = WorkshopReadIssue.message(for: failure) {
            error = nil
            connectionIssue = message
            needsHistoryRefresh = true
        } else { error = failure.localizedDescription }
    }

    private func clearConnectionIssue() {
        if let started = syncFailureStarted {
            store.recordDiagnostic("sync_recovered", detail: "operation=\(operationId ?? "none"); downtimeMs=\(Int(Date.now.timeIntervalSince(started) * 1000)); failures=\(syncFailureCount)")
            HakoLog.record(.codeWorkshop, "会话同步已恢复", detail:
                "operation=\(operationId ?? "none"); downtimeMs=\(Int(Date.now.timeIntervalSince(started) * 1000)); failures=\(syncFailureCount)")
        }
        syncFailureStarted = nil
        syncFailureCount = 0
        lastSyncFailureCode = nil
        lastSyncFailureLog = nil
        connectionIssue = nil
    }

    func pendingSend(_ id: String) -> WorkshopQueuedSend? {
        guard let operationId else { return nil }
        return store.pendingQueue(operationId: operationId).first { $0.id == id }
    }

    func retryQueued(_ id: String) async {
        guard canRetryDelivery(id), let queued = pendingSend(id) else { return }
        await submitQueued(queued)
    }

    private func submitQueued(_ queued: WorkshopQueuedSend) async {
        guard scope == store.scope, !busy, !uncertain,
              store.pendingQueue(operationId: queued.operationId).first?.id == queued.id else { return }
        busy = true; error = nil; cancelledUploadID = nil
        outbox.begin(queued.id, images: !queued.imageIds.isEmpty)
        var submitted = false, accepted = false
        defer {
            busy = false; imageUpload = nil; outbox.finish(queued.id)
            resumePendingSends()
        }
        do {
            try await requireThreadAccess()
            try await uploadMessageImages(queued.imageIds, id: queued.id)
            guard scope == store.scope else { throw CancellationError() }
            outbox.sending(queued.id); submitted = true
            let result: WorkshopFollowupReply = try await store.call(agent, "message.queue", queued.parameters)
            guard scope == store.scope, operationId == queued.operationId, result.id == queued.id else { throw CancellationError() }
            accepted = true; outbox.acknowledge(queued.id)
            acceptFollowup(result)
            clearSentDraft(queued.message, imageIds: queued.imageIds, id: queued.id)
            try store.saveQueuedSend(nil, removing: queued.id)
            observedTerminal = nil
            try await poll(queued.operationId)
        } catch is CancellationError {
            if !accepted, outbox.states[queued.id] != nil, scope == store.scope {
                outbox.failed(queued.id, message: submitted ? "排队结果待确认，请检查结果或重试原消息。" : "上传已取消，文字和图片已保留。", submitted: submitted)
            }
        }
        catch let failure as WorkshopFailure where ["invalid_params", "codex_queue_full", "codex_image_missing", "codex_image_invalid", "codex_thread_occupied", "codex_thread_access_unknown"].contains(failure.code) {
            guard scope == store.scope else { return }
            if accepted || outbox.states[queued.id] == nil { readFailed(failure); return }
            accessRejected(failure)
            store.rejectQueuedActivity(queued, agent: agent, scope: scope)
            outbox.failed(queued.id, message: failure.message, submitted: false)
        }
        catch {
            guard scope == store.scope else { return }
            if accepted || outbox.states[queued.id] == nil { readFailed(error) }
            else { outbox.failed(queued.id, message: (submitted ? "排队结果尚未确认。" : "图片上传失败。") + error.localizedDescription, submitted: submitted) }
        }
    }

    private func acceptFollowup(_ result: WorkshopFollowupReply) {
        followups = WorkshopFollowupState.merging([result.status], into: followups)
        guard followups.first(where: { $0.id == result.id }) == result.status else { return }
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
