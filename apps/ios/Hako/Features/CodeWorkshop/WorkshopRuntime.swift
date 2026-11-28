import Combine
import UIKit

@MainActor final class WorkshopRuntime {
    static let shared = WorkshopRuntime()
    let store: WorkshopStore
    private struct Retained { let conversation: WorkshopConversation; var usedAt: Date }
    private var conversations: [UUID: Retained] = [:]
    private var visibility = WorkshopConversationVisibility()
    let visibilityChanges = PassthroughSubject<Void, Never>()
    private let synchronization = WorkshopSynchronization()
    private let catalogID = UUID()
    private var context: String
    private var subscriptions: Set<AnyCancellable> = []
    private var cleanup: Task<Void, Never>?

    private init() {
        store = WorkshopStore()
        store.setConnectionForeground(UIApplication.shared.applicationState != .background)
        context = store.scope
        registerCatalog()
        store.sessionArchived.sink { [weak self] notice in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let matches = self.conversations.filter { $0.value.conversation.scope == notice.scope &&
                    $0.value.conversation.agent.id == notice.agentID && $0.value.conversation.threadId == notice.threadID }
                for (id, retained) in matches {
                    self.synchronization.remove(id)
                    retained.conversation.discardCacheAfterArchive()
                    self.conversations[id] = nil
                }
            }
        }.store(in: &subscriptions)
        synchronization.setForeground(UIApplication.shared.applicationState != .background)
        store.authentication.changes.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.resetContext() }
        }.store(in: &subscriptions)
        store.routeChanges.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.resetContext()
                self?.synchronization.restart()
            }
        }.store(in: &subscriptions)
        LocalNetworkService.shared.changes.sink { [weak self] _ in
            Task { @MainActor [weak self] in await self?.store.prepareNetwork() }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification).sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.synchronization.setForeground(false)
                self.store.setConnectionForeground(false)
                let background = UIApplication.shared.beginBackgroundTask(withName: "Save Workshop drafts")
                await self.store.flushComposerDrafts()
                if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
            }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification).sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                for id in self.visibility.foreground { self.conversations[id]?.conversation.prepareForDisplay() }
                self.store.setConnectionForeground(true)
                await self.store.prepareNetwork()
                self.synchronization.setForeground(true)
            }
        }.store(in: &subscriptions)
    }

    func enter(_ owner: UUID, conversation: WorkshopConversation? = nil, preview: Bool = false) {
        Task { await store.prepareNetwork() }
        resetContext()
        cleanup?.cancel(); cleanup = nil
        if let conversation {
            visibility.enter(owner, conversation: conversation.id, preview: preview)
            retain(conversation)
            if let notice = BuildPushSubscription.shared.workshopBanner, isViewing(notice) {
                BuildPushSubscription.shared.dismissWorkshopNotice()
            }
        }
        if !synchronization.hasVisibleOwners {
            store.beginVisit()
            Task { await store.loadComputers() }
        }
        synchronization.enter(owner, conversation: conversation != nil)
        updateNetworkVisibility()
        visibilityChanges.send()
    }

    func isForegroundConversation(_ id: UUID) -> Bool {
        visibility.foreground.contains(id)
    }

    func isViewing(_ notice: WorkshopPushNotice) -> Bool {
        guard UIApplication.shared.applicationState == .active else { return false }
        return visibility.foreground.contains { id in
            guard let conversation = conversations[id]?.conversation, conversation.scope == store.scope else { return false }
            return notice.belongsToConversation(computerId: conversation.agent.id, threadId: conversation.threadId,
                operationId: conversation.notificationOperationID)
        }
    }

    func leave(_ owner: UUID, conversation: WorkshopConversation? = nil) {
        if let conversation {
            visibility.leave(owner)
            conversations[conversation.id]?.usedAt = .now
        }
        synchronization.leave(owner)
        updateNetworkVisibility()
        visibilityChanges.send()
        guard !synchronization.hasVisibleOwners else { return }
        cleanup?.cancel()
        cleanup = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(300)) } catch { return }
            guard let self, !self.synchronization.hasVisibleOwners else { return }
            for id in self.conversations.keys { self.synchronization.remove(id) }
            self.conversations.removeAll()
        }
    }

    func open(_ session: WorkshopSession, agent: WorkshopAgent, application: WorkshopApplication, archived: Bool) -> WorkshopConversation {
        resetContext()
        let key = WorkshopConversationReuseKey(scope: store.scope, agentId: agent.id,
            applicationId: application.id, sessionId: session.id, archived: archived)
        if let existing = conversations.values.first(where: { $0.conversation.reuseKey == key })?.conversation {
            if existing.title == session.title, existing.application == application, existing.agent.name == agent.name {
                existing.prepareForReentry(session)
                retain(existing)
                return existing
            }
            synchronization.remove(existing.id)
            conversations[existing.id] = nil
        }
        let value = WorkshopConversation(store: store, agent: agent, application: application, session: session, archived: archived)
        retain(value)
        return value
    }

    func create(agent: WorkshopAgent, application: WorkshopApplication, title: String, parentThreadId: String? = nil, initialChoice: WorkshopChoice? = nil) -> WorkshopConversation {
        resetContext()
        let value = WorkshopConversation(store: store, agent: agent, application: application, title: title,
            parentThreadId: parentThreadId, initialChoice: initialChoice)
        retain(value)
        return value
    }

    // Resolve a notification without changing the project/computer selection
    // underneath a preview. A later full-page switch reuses this same object.
    func notificationConversation(_ notice: WorkshopPushNotice) async throws -> WorkshopConversation {
        try await pageConversation(computerID: notice.computerId, threadID: notice.threadId, title: notice.subtitle)
    }

    func pageConversation(computerID: String, threadID: String, title: String) async throws -> WorkshopConversation {
        resetContext()
        guard UUID(uuidString: threadID) != nil else { throw HakoError(message: "此页面没有可打开的会话。") }
        if let existing = conversations.values.first(where: {
            $0.conversation.scope == store.scope && $0.conversation.agent.id == computerID &&
            $0.conversation.threadId?.caseInsensitiveCompare(threadID) == .orderedSame
        })?.conversation {
            retain(existing)
            return existing
        }
        await store.prepareNetwork()
        if !store.authenticated || !store.agents.contains(where: { $0.id == computerID }) { await store.restore() }
        try Task.checkCancellation()
        let scope = store.scope
        guard store.authenticated, let agent = store.agents.first(where: { $0.id == computerID }) else {
            throw HakoError(message: "页面对应的电脑当前不可用，请检查连接。")
        }
        if store.selectedAgentID == agent.id,
           let session = store.sessions.first(where: { $0.id.caseInsensitiveCompare(threadID) == .orderedSame }),
           let application = store.applications.first(where: { $0.id == session.applicationId }) {
            return open(session, agent: agent, application: application, archived: store.showingArchived)
        }
        let catalog: WorkshopCatalog = try await store.call(agent, "applications.list")
        try Task.checkCancellation()
        guard scope == store.scope else { throw CancellationError() }
        if let session = catalog.sessions.first(where: { $0.id.caseInsensitiveCompare(threadID) == .orderedSame }),
           let application = catalog.applications.first(where: { $0.id == session.applicationId }) {
            return open(session, agent: agent, application: application, archived: false)
        }
        let history: WorkshopHistory = try await store.call(agent, "history.read", ["threadId": threadID])
        try Task.checkCancellation()
        guard scope == store.scope else { throw CancellationError() }
        guard let application = WorkshopApplication.containing(history.cwd, in: catalog.applications) else {
            throw HakoError(message: "页面对应的项目已不可用。")
        }
        let session = WorkshopSession(id: threadID, title: title.isEmpty ? "会话" : title,
            applicationId: application.id, cwd: history.cwd, preview: "", updatedAt: Int64(Date.now.timeIntervalSince1970),
            state: "unknown", operationId: history.operationId, completionId: history.completionId, parentThreadId: history.parentThreadId)
        return open(session, agent: agent, application: application, archived: false)
    }

    private func retain(_ conversation: WorkshopConversation) {
        guard conversation.scope == store.scope else { return }
        conversations[conversation.id] = Retained(conversation: conversation, usedAt: .now)
        synchronization.register(conversation.id, kind: .conversation) { await conversation.watch() }
        if conversations.count > 6, let oldest = conversations.values
            .filter({ $0.conversation.id != conversation.id && !visibility.contains($0.conversation.id) })
            .min(by: { $0.usedAt < $1.usedAt })?.conversation.id {
            synchronization.remove(oldest)
            conversations[oldest] = nil
        }
    }

    private func updateNetworkVisibility() {
        let foreground = visibility.foreground
        for item in conversations.values { item.conversation.networkVisible = foreground.contains(item.conversation.id) }
    }

    private func resetContext() {
        guard context != store.scope else { return }
        context = store.scope
        cleanup?.cancel(); cleanup = nil
        synchronization.removeAll()
        conversations.removeAll(); visibility = WorkshopConversationVisibility()
        registerCatalog()
    }

    private func registerCatalog() {
        let store = store
        synchronization.register(catalogID, kind: .catalog) {
            await store.prepareNetwork()
            if store.authenticated { await store.loadComputers(); await store.refresh() } else { await store.restore() }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                await store.refresh(reconcile: false)
            }
        }
    }
}
