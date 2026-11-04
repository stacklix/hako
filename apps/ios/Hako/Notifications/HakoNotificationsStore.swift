import Foundation
import Combine

@MainActor final class HakoNotificationsStore: ObservableObject {
    private struct Snapshot { var context = ""; var items: [HakoNotification] = [] }
    private static let dismissalKey = "hako.notifications.dismissals.v1"
    @Published private var snapshot = Snapshot()
    @Published private var now = Date.now
    @Published private var dismissals: NotificationDismissals
    @Published private(set) var message: String?
    private let authentication: any AuthenticatedServerAccess
    private let defaults: UserDefaults
    private var subscription: AnyCancellable?

    init(authentication: (any AuthenticatedServerAccess)? = nil, defaults: UserDefaults = .standard) {
        self.authentication = authentication ?? AuthenticatedServerService.shared
        self.defaults = defaults
        dismissals = defaults.data(forKey: Self.dismissalKey).flatMap { try? JSONDecoder().decode(NotificationDismissals.self, from: $0) } ?? NotificationDismissals()
        if dismissals.prune(), let data = try? JSONEncoder().encode(dismissals) { defaults.set(data, forKey: Self.dismissalKey) }
        subscription = self.authentication.changes.sink { [weak self] _ in self?.objectWillChange.send() }
    }
    var context: String { authentication.requestContext }
    var authenticated: Bool { authentication.authenticated && !authentication.logoutPending }
    private var scope: String { NotificationDismissals.scope(server: authentication.serverURL, account: authentication.username) }
    var notifications: [HakoNotification] {
        guard authenticated, snapshot.context == context else { return [] }
        return snapshot.items.filter { $0.expiresAt > now && !dismissals.contains($0.id, scope: scope, now: now) }
    }
    // Include cleared reminders when checking whether an open request is still
    // actionable. Dismissing a reminder must never invalidate its authorization.
    var activeIDs: [String] {
        guard authenticated, snapshot.context == context else { return [] }
        return snapshot.items.filter { $0.expiresAt > now }.map(\.id)
    }
    func clear(_ notification: HakoNotification) {
        now = .now
        guard notifications.contains(where: { $0.id == notification.id }) else { return }
        dismissals.clear(notification, scope: scope)
        saveDismissals()
    }
    func markProcessed(_ notification: HakoNotification, context expected: String) {
        guard authenticated, expected == context else { return }
        dismissals.clear(notification, scope: scope)
        saveDismissals()
    }
    func clearAll() {
        now = .now
        for notification in notifications { dismissals.clear(notification, scope: scope) }
        saveDismissals()
    }
    private func saveDismissals() {
        if let data = try? JSONEncoder().encode(dismissals) { defaults.set(data, forKey: Self.dismissalKey) }
    }

    func run() async {
        let expected = context
        if snapshot.context != expected { snapshot = Snapshot(context: expected); message = nil }
        let clock = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                self?.now = .now
            }
        }
        defer { clock.cancel() }
        var retrySeconds = 3
        while !Task.isCancelled, context == expected, authenticated {
            do {
                try await authentication.watchLoginPrompts { [weak self] data in
                    guard let self, self.context == expected else { throw CancellationError() }
                    try self.apply(data, context: expected, issuer: self.authentication.serverURL)
                    retrySeconds = 3
                }
                try Task.checkCancellation()
            } catch {
                guard !Task.isCancelled, context == expected, authenticated else { return }
                now = .now
                message = "通知连接已断开，正在重连，已保留尚未到期的内容。\n" + error.localizedDescription
            }
            do { try await Task.sleep(for: .seconds(retrySeconds)) } catch { return }
            retrySeconds = min(retrySeconds * 2, 60)
        }
    }

    private func apply(_ data: Data, context expected: String, issuer: String) throws {
        let list = try JSONDecoder().decode(ConsoleLoginPromptList.self, from: data)
        try list.validate(origin: issuer)
        let items = list.requests.map { HakoNotification(loginRequest: $0) }.sorted {
            if $0.createdAt != $1.createdAt { return ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
            return $0.id < $1.id
        }
        if snapshot.context != expected || snapshot.items != items { snapshot = Snapshot(context: expected, items: items) }
        now = .now
        if dismissals.prune(now: now) { saveDismissals() }
        message = nil
    }
}
