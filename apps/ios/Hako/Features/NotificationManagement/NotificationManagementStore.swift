import Foundation
import Combine

@MainActor final class NotificationManagementStore: ObservableObject {
    private let authentication: any AuthenticatedServerAccess
    private var subscription: AnyCancellable?
    private struct Snapshot {
        var context = ""
        var hooks: [HakoWebhook] = []
        var wechat: HakoNotificationWechat?
        var loaded = false
        var error: String?
        var channelError: String?
    }
    @Published private var snapshot = Snapshot()
    @Published private(set) var loading = false
    @Published private(set) var working = false
    private var loadID: UUID?

    init(authentication: (any AuthenticatedServerAccess)? = nil) {
        self.authentication = authentication ?? AuthenticatedServerService.shared
        subscription = self.authentication.changes.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
    var context: String { authentication.requestContext }
    var authenticated: Bool { authentication.authenticated && !authentication.logoutPending }
    var origin: String { authentication.serverURL }
    private var current: Snapshot { snapshot.context == context ? snapshot : Snapshot() }
    var hooks: [HakoWebhook] { current.hooks }
    var wechat: HakoNotificationWechat? { current.wechat }
    var loaded: Bool { current.loaded }
    var error: String? { current.error }
    var channelError: String? { current.channelError }

    func prepare() async {
        await authentication.restore()
        if authenticated { await refresh() }
    }

    func request<T: Decodable>(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> T {
        let startedContext = context
        guard authenticated else { throw HakoNotificationError(message: "请先在“服务器与登录”中登录 Sora。") }
        do {
            let data = try await authentication.send("/api/v1/notifications/manage" + path, method: method, body: body, logSource: .hako)
            try Task.checkCancellation()
            guard context == startedContext else { throw CancellationError() }
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            guard context == startedContext else { throw CancellationError() }
            throw error
        }
    }

    func refresh() async {
        let startedContext = context, id = UUID()
        loadID = id; loading = true
        if snapshot.context != startedContext { snapshot = Snapshot(context: startedContext) }
        defer { if loadID == id { loading = false } }
        do {
            let hooks: [HakoWebhook] = try await request("/webhooks")
            guard context == startedContext, loadID == id else { return }
            snapshot.hooks = hooks; snapshot.loaded = true; snapshot.error = nil
        } catch is CancellationError { return }
        catch {
            if context == startedContext, loadID == id { snapshot.error = error.localizedDescription }
            return
        }
        do {
            let wechat: HakoNotificationWechat = try await request("/channels/wechat")
            guard context == startedContext, loadID == id else { return }
            snapshot.wechat = wechat; snapshot.channelError = nil
        } catch is CancellationError { }
        catch {
            if context == startedContext, loadID == id { snapshot.channelError = error.localizedDescription }
        }
    }

    // Writes are serialized and are never automatically replayed after a
    // transport failure. The caller can refresh to check an uncertain result.
    func mutate<T: Decodable>(_ path: String, method: String, body: [String: Any]? = nil) async throws -> T {
        guard !working else { throw HakoNotificationError(message: "正在提交其他操作，请稍后重试。") }
        working = true
        defer { working = false }
        return try await request(path, method: method, body: body)
    }

    func update(_ hook: HakoWebhook) {
        guard snapshot.context == context else { return }
        // A refresh started before the write must not overwrite its result.
        loadID = nil; loading = false; snapshot.error = nil
        if let index = snapshot.hooks.firstIndex(where: { $0.id == hook.id }) { snapshot.hooks[index] = hook }
        else { snapshot.hooks.insert(hook, at: 0) }
    }
    func remove(_ id: String) {
        guard snapshot.context == context else { return }
        loadID = nil; loading = false; snapshot.error = nil
        snapshot.hooks.removeAll { $0.id == id }
    }
    static func path(_ id: String) -> String {
        "/webhooks/" + id.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
    }
}
