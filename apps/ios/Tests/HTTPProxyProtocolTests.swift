import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum HakoLogSource { case hako }
@MainActor enum AuthenticatedServerService { static let shared = ProxyTestAccess() }
@MainActor enum HakoHTTPProxyClient {
    static func send(agentID: String, parameters: [String: Any]) async throws -> Data {
        try await AuthenticatedServerService.shared.send("/ws/proxy/client/" + agentID, method: "WS",
            body: ["version": 1, "request": parameters], logSource: .hako)
    }
}
@MainActor final class ProxyTestAccess {
    let serverURL = "https://proxy-test.invalid"
    let username = "test-" + UUID().uuidString
    var authenticated = true
    var logoutPending = false
    var requestContext = "original"
    var version = "0.8.16"
    var failure: String?
    var invalidate = false
    var stall = false
    var requests = 0
    func send(_ path: String, method: String, body: [String: Any]?, logSource: HakoLogSource) async throws -> Data {
        if path == "/api/v1/version" { return try JSONSerialization.data(withJSONObject: ["serverVersion": version]) }
        precondition(path == "/ws/proxy/client/fixture" && method == "WS")
        precondition(body?["method"] == nil && body?["version"] as? Int == 1)
        let parameters = body?["request"] as! [String: Any]
        precondition(parameters["target"] as? String == "127.0.0.1:8080")
        precondition(parameters["url"] as? String == "http://unreachable.invalid/a%2Fb?q=1")
        precondition(parameters["body"] as? String == "AP-A")
        let headers = parameters["headers"] as! [String: String]
        precondition(!headers.keys.contains { $0.lowercased() == "x-proxy" })
        precondition(headers["Authorization"] == "Bearer target-secret")
        requests += 1
        if stall { try await Task.sleep(for: .seconds(30)) }
        if invalidate { requestContext = UUID().uuidString }
        if let failure { return try JSONSerialization.data(withJSONObject: ["error": ["code": "proxy_failed", "message": failure]]) }
        return try JSONSerialization.data(withJSONObject: ["result": ["status": 404, "headers": ["Content-Type": "application/octet-stream"], "body": "AP-A"]])
    }
}

@main struct HTTPProxyProtocolTests {
    @MainActor static func main() async throws {
        let access = AuthenticatedServerService.shared
        let key = HakoHTTPProxy.settingsKey(server: access.serverURL, account: access.username)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HakoProxyURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "http://unreachable.invalid/a%2Fb?q=1")!)
        request.httpMethod = "POST"
        request.httpBody = Data([0, 255, 128])
        precondition(!HakoProxyURLProtocol.canInit(with: request))
        request.setValue("127.0.0.1:8080", forHTTPHeaderField: "X-Proxy")
        request.setValue("Bearer target-secret", forHTTPHeaderField: "Authorization")
        do { _ = try await session.data(for: request); preconditionFailure("Missing Agent allowed direct connection") } catch { }
        precondition(access.requests == 0)
        UserDefaults.standard.set("fixture", forKey: key)
        let (data, response) = try await session.data(for: request)
        precondition(data == Data([0, 255, 128]) && (response as? HTTPURLResponse)?.statusCode == 404)
        precondition(response.url == request.url && access.requests == 1)
        access.version = "0.8.15"
        do { _ = try await session.data(for: request); preconditionFailure("Old relay received a mutating request") } catch { }
        precondition(access.requests == 1)
        access.version = "0.8.16"
        access.failure = "Test target error"
        do { _ = try await session.data(for: request); preconditionFailure("Agent error lost") } catch {
            precondition(error.localizedDescription.contains("Test target error"))
        }
        access.failure = nil; access.stall = true
        let pending = Task { try await session.data(for: request) }
        while access.requests < 3 { await Task.yield() }
        pending.cancel()
        do { _ = try await pending.value; preconditionFailure("Cancellation ignored") } catch { }
        print("PASS: real URLSession proxy interception, authenticated proxy WebSocket envelope, status/binary response, missing settings, relay version, Agent error and cancellation")
    }
}
