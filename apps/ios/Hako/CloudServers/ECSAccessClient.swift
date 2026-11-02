import Foundation
import Combine

@MainActor final class ECSAccessAPI: ObservableObject, ECSAccessRecordsReading {
    static let shared = ECSAccessAPI()
    private let authentication: any AuthenticatedServerAccess
    private var subscription: AnyCancellable?
    init(authentication: (any AuthenticatedServerAccess)? = nil) {
        let authentication = authentication ?? AuthenticatedServerService.shared
        self.authentication = authentication
        subscription = authentication.changes.sink { [weak self] _ in self?.objectWillChange.send() }
    }
    var serverURL: String { authentication.serverURL }
    var username: String { authentication.username }
    var authenticated: Bool { authentication.authenticated }
    var logoutPending: Bool { authentication.logoutPending }
    var requestContext: String { authentication.requestContext }
    func restore() async { await authentication.restore() }

    // Read-only access statistics use the same registered identity and token
    // refresh path as device management. Never reuse a response across accounts.
    func accessLogs<T: Decodable>(_ type: T.Type, rankings: Bool = false,
                                  range: ECSAccessRange = .day, domain: String = "",
                                  from: String? = nil, to: String? = nil, hour: String? = nil) async throws -> T {
        let path = ECSAccessQuery.path(rankings: rankings, range: range, domain: domain, from: from, to: to, hour: hour)
        return try await read(type, path: path)
    }

    func accessRecords(query: String) async throws -> ECSAccessRecords {
        try await read(ECSAccessRecords.self, path: "/api/v1/access-logs/records?" + query)
    }

    private func read<T: Decodable>(_ type: T.Type, path: String) async throws -> T {
        guard authenticated, !logoutPending else { throw HakoError(message: "请先在“服务器与登录”中登录 Hako 服务器。") }
        let context = requestContext
        let data: Data
        do { data = try await authentication.send(path, method: "GET", body: nil, logSource: .cloudServers) }
        catch let error as ServerHTTPError where error.status == 404 || error.status == 405 {
            guard context == requestContext else { throw CancellationError() }
            throw HakoError(message: "服务端尚不支持 App 访问统计，请先更新 Hako 服务端。")
        } catch {
            guard context == requestContext else { throw CancellationError() }
            throw error
        }
        try Task.checkCancellation()
        guard context == requestContext, authenticated, !logoutPending else { throw CancellationError() }
        do { return try JSONDecoder().decode(type, from: data) }
        catch DecodingError.keyNotFound(let key, _) where ["success", "nonSuccess", "successURLs", "nonSuccessPages", "nonSuccessURLs"].contains(key.stringValue) {
            throw HakoError(message: "服务端尚不支持 2xx／非 2xx 统计，请先更新 Hako 服务端。")
        }
    }
}
