import Foundation
import Combine

@MainActor final class ConsoleLoginRequestsStore: ObservableObject {
    private struct Snapshot { var context = ""; var requests: [ConsoleLoginPrompt] = [] }
    @Published private var snapshot = Snapshot()
    @Published private(set) var loading = false
    @Published private(set) var message: String?
    private let client = ConsoleClient.shared
    var context: String { client.requestContext }
    var requests: [ConsoleLoginPrompt] {
        guard client.authenticated, !client.logoutPending, snapshot.context == context else { return [] }
        return snapshot.requests.filter { ($0.expiry ?? .distantPast) > .now }
    }

    func run() async {
        let expected = context
        if snapshot.context != expected { snapshot = Snapshot(context: expected); message = nil }
        while !Task.isCancelled, context == expected, client.authenticated, !client.logoutPending {
            await refresh()
            do { try await Task.sleep(for: .seconds(message == nil ? 3 : 15)) } catch { return }
        }
    }

    func refresh() async {
        guard !loading, client.authenticated, !client.logoutPending else { return }
        let expected = context
        loading = true
        defer { loading = false }
        do {
            let requests = try await client.pendingLoginPrompts()
            try Task.checkCancellation()
            guard expected == context else { return }
            snapshot = Snapshot(context: expected, requests: requests); message = nil
        } catch {
            guard !Task.isCancelled, expected == context else { return }
            snapshot = Snapshot(context: expected)
            message = (error as? ServerHTTPError)?.status == 404 ? "服务端尚不支持登录请求通知，请先更新服务端；扫码登录仍可使用。" : error.localizedDescription
        }
    }
}
