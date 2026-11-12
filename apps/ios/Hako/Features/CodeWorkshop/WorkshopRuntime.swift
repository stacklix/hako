import Combine
import UIKit

@MainActor final class WorkshopRuntime {
    static let shared = WorkshopRuntime()
    let store: WorkshopStore
    private struct Retained { let conversation: WorkshopConversation; var usedAt: Date }
    private var conversations: [UUID: Retained] = [:]
    private var visibleConversations: Set<UUID> = []
    private let synchronization = WorkshopSynchronization()
    private let catalogID = UUID()
    private var context: String
    private var subscriptions: Set<AnyCancellable> = []
    private var cleanup: Task<Void, Never>?

    private init() {
        store = WorkshopStore()
        context = store.scope
        registerCatalog()
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
            Task { @MainActor [weak self] in self?.synchronization.setForeground(false) }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification).sink { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.store.prepareNetwork()
                self?.synchronization.setForeground(true)
            }
        }.store(in: &subscriptions)
    }

    func enter(_ owner: UUID, conversation: WorkshopConversation? = nil) {
        Task { await store.prepareNetwork() }
        resetContext()
        cleanup?.cancel(); cleanup = nil
        if let conversation {
            visibleConversations.insert(conversation.id)
            retain(conversation)
            if let notice = BuildPushSubscription.shared.workshopBanner, isViewing(notice) {
                BuildPushSubscription.shared.dismissWorkshopNotice()
            }
        }
        synchronization.enter(owner, conversation: conversation != nil)
    }

    func isViewing(_ notice: WorkshopPushNotice) -> Bool {
        guard UIApplication.shared.applicationState == .active else { return false }
        return visibleConversations.contains { id in
            guard let conversation = conversations[id]?.conversation, conversation.scope == store.scope else { return false }
            return notice.belongsToConversation(computerId: conversation.agent.id, threadId: conversation.threadId,
                operationId: conversation.notificationOperationID)
        }
    }

    func leave(_ owner: UUID, conversation: WorkshopConversation? = nil) {
        if let conversation {
            visibleConversations.remove(conversation.id)
            conversations[conversation.id]?.usedAt = .now
        }
        synchronization.leave(owner)
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

    func create(agent: WorkshopAgent, application: WorkshopApplication, title: String) -> WorkshopConversation {
        resetContext()
        let value = WorkshopConversation(store: store, agent: agent, application: application, title: title)
        retain(value)
        return value
    }

    private func retain(_ conversation: WorkshopConversation) {
        guard conversation.scope == store.scope else { return }
        conversations[conversation.id] = Retained(conversation: conversation, usedAt: .now)
        synchronization.register(conversation.id, kind: .conversation) { await conversation.watch() }
        if conversations.count > 6, let oldest = conversations.values
            .filter({ $0.conversation.id != conversation.id && !visibleConversations.contains($0.conversation.id) })
            .min(by: { $0.usedAt < $1.usedAt })?.conversation.id {
            synchronization.remove(oldest)
            conversations[oldest] = nil
        }
    }

    private func resetContext() {
        guard context != store.scope else { return }
        context = store.scope
        cleanup?.cancel(); cleanup = nil
        synchronization.removeAll()
        conversations.removeAll(); visibleConversations.removeAll()
        registerCatalog()
    }

    private func registerCatalog() {
        let store = store
        synchronization.register(catalogID, kind: .catalog) {
            await store.prepareNetwork()
            if store.authenticated { await store.refresh() } else { await store.restore() }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                await store.refresh()
            }
        }
    }
}
