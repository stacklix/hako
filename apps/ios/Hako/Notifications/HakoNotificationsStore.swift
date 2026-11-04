import Foundation
import Combine

@MainActor final class HakoNotificationsStore: ObservableObject {
    private struct Snapshot { var context = ""; var items: [HakoNotification] = [] }
    private static let dismissalKey = "hako.notifications.dismissals.v1"
    @Published private var snapshot = Snapshot()
    @Published private var now = Date.now
    @Published private var dismissals: NotificationDismissals
    @Published private(set) var message: String?
    private var refreshing = false
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
        while !Task.isCancelled, context == expected, authenticated {
            await refresh()
            do { try await Task.sleep(for: .seconds(message == nil ? 3 : 15)) } catch { return }
        }
    }

    func refresh() async {
        guard !refreshing, authenticated else { return }
        let expected = context, issuer = authentication.serverURL
        refreshing = true
        defer { refreshing = false }
        do {
            let data = try await authentication.send("/api/v1/auth/login-prompts", method: "GET", body: nil, logSource: .hako)
            try Task.checkCancellation()
            guard expected == context else { return }
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
        } catch {
            guard !Task.isCancelled, expected == context else { return }
            now = .now
            // Keep the last successful snapshot on a transient failure. It is
            // still bounded by expiry and every action is checked by the server.
            if snapshot.context != expected { snapshot = Snapshot(context: expected) }
            message = (error as? ServerHTTPError)?.status == 404 ? "服务端尚不支持通知列表，请先更新服务端；扫码登录仍可使用。" : "暂时无法更新通知，已保留上次获取的内容。\n" + error.localizedDescription
        }
    }
}
