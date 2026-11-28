import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class ProxyProbeClient: NSObject, URLProtocolClient, @unchecked Sendable {
    func urlProtocol(_ protocolObject: URLProtocol, wasRedirectedTo request: URLRequest, redirectResponse: URLResponse) { }
    func urlProtocol(_ protocolObject: URLProtocol, cachedResponseIsValid cachedResponse: CachedURLResponse) { }
    func urlProtocol(_ protocolObject: URLProtocol, didReceive response: URLResponse, cacheStoragePolicy policy: URLCache.StoragePolicy) { }
    func urlProtocol(_ protocolObject: URLProtocol, didLoad data: Data) { }
    func urlProtocolDidFinishLoading(_ protocolObject: URLProtocol) { }
    func urlProtocol(_ protocolObject: URLProtocol, didFailWithError error: Error) { }
    func urlProtocol(_ protocolObject: URLProtocol, didReceive challenge: URLAuthenticationChallenge) { }
    func urlProtocol(_ protocolObject: URLProtocol, didCancel challenge: URLAuthenticationChallenge) { }
}

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
    var version = "0.9.5"
    var failure: String?
    var invalidate = false
    var stall = false
    var requests = 0
    var expectedBody = "AP-A"
    func send(_ path: String, method: String, body: [String: Any]?, logSource: HakoLogSource) async throws -> Data {
        if path == "/api/v1/version" { return try JSONSerialization.data(withJSONObject: ["serverVersion": version]) }
        precondition(path == "/ws/proxy/client/fixture" && method == "WS")
        precondition(body?["method"] == nil && body?["version"] as? Int == 1)
        let parameters = body?["request"] as! [String: Any]
        precondition(parameters["target"] as? String == "127.0.0.1:8080")
        precondition(parameters["url"] as? String == "http://unreachable.invalid/a%2Fb?q=1")
        precondition(parameters["body"] as? String == expectedBody)
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
        for version in ["0.8.16", "0.9.2", "0.10.0", "1.0.0", "0..9.5", "0.9.5.", "0.9.5-beta"] {
            access.version = version
            do { _ = try await HakoProxyURLProtocol.forward(request); preconditionFailure("Unsupported relay received a mutating request") } catch {
                precondition(error.localizedDescription.contains(HakoServerCompatibility.serverWarning(for: version)!))
            }
            precondition(access.requests == 1, "Rejected version must not forward the request")
        }
        access.version = "0.9.5"
        access.failure = "Test target error"
        do { _ = try await session.data(for: request); preconditionFailure("Agent error lost") } catch {
            precondition(error.localizedDescription.contains("Test target error"))
        }
        access.failure = nil; access.stall = true
        let pending = Task { try await session.data(for: request) }
        while access.requests < 3 { await Task.yield() }
        pending.cancel()
        do { _ = try await pending.value; preconditionFailure("Cancellation ignored") } catch { }

        access.stall = false
        // Capture a URLSession-owned, single-use stream synchronously, before
        // main-actor authentication can suspend its consumption.
        var streamed = request
        streamed.httpBody = nil
        let stream = InputStream(data: Data([0, 255, 128]))
        streamed.httpBodyStream = stream
        let probeClient = ProxyProbeClient()
        let intercepted = HakoProxyURLProtocol(request: streamed, cachedResponse: nil, client: probeClient)
        let beforeStream = access.requests
        intercepted.startLoading()
        // Simulate URLSession consuming/closing its stream after the hand-off.
        // The eventual forwarded body must still contain all original bytes.
        stream.open()
        var drained = [UInt8](repeating: 0, count: 16)
        while stream.read(&drained, maxLength: drained.count) > 0 { }
        stream.close()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while access.requests == beforeStream && ContinuousClock.now < deadline { await Task.yield() }
        precondition(access.requests == beforeStream + 1, "Captured body was not forwarded exactly once")
        intercepted.stopLoading()
        await Task.yield()

        // The shared transport can bypass URLSession body normalization entirely.
        // Keep login JSON, Unicode and binary bytes intact across authentication.
        let loginBody = Data(#"{"method":"do","login":{"password":"fixture-only-%2B"},"label":"路由器"}"#.utf8)
        var login = request
        login.httpBody = loginBody
        access.expectedBody = HakoHTTPProxy.encodeBody(loginBody)
        let beforeLogin = access.requests
        _ = try await HakoProxyURLProtocol.forward(login)
        precondition(access.requests == beforeLogin + 1, "Forwarding repeated the login request")
        #if os(iOS)
        let beforeTransport = access.requests
        _ = try await HTTPTransport.data(for: login, using: session, logBody: false)
        precondition(access.requests == beforeTransport + 1, "Shared transport did not preserve the original login body")
        precondition(!HakoLogStore.shared.snapshot().entries.map(\.text).joined().contains("fixture-only-%2B"),
                     "Hidden login body leaked through proxy diagnostics")
        #endif
        access.invalidate = true
        do { _ = try await HakoProxyURLProtocol.forward(login); preconditionFailure("Account switch accepted an old response") }
        catch is CancellationError { }
        print("PASS: real URLSession proxy interception, authenticated proxy WebSocket envelope, status/binary response, missing settings, relay version, Agent error and cancellation")
    }
}
