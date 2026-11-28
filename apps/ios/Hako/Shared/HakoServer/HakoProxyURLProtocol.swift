import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Every shared HTTPTransport session applies this before DNS or a direct connection.
final class HakoProxyURLProtocol: URLProtocol, @unchecked Sendable {
    private var operation: Task<Void, Never>?
    private let stateLock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: "X-Proxy") != nil
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        // Take ownership of the body while URLSession is handing us the request,
        // before deferring authentication and forwarding to the main actor.
        let prepared = Result { try HakoHTTPProxy.parameters(request) }
        let task = Task { @MainActor [self] in
            do {
                let (body, response) = try await Self.forward(request, parameters: prepared.get())
                try Task.checkCancellation()
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: body)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                if !Task.isCancelled { client?.urlProtocol(self, didFailWithError: error) }
            }
        }
        stateLock.lock()
        if stopped { task.cancel() } else { operation = task }
        stateLock.unlock()
    }

    // Shared HTTPTransport calls this with the original request, before
    // URLSession can turn a Data body into a single-use stream.
    @MainActor static func forward(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await forward(request, parameters: HakoHTTPProxy.parameters(request))
    }

    @MainActor private static func forward(_ request: URLRequest, parameters: [String: Any]) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let authentication = AuthenticatedServerService.shared
        let context = authentication.requestContext
        let key = HakoHTTPProxy.settingsKey(server: authentication.serverURL, account: authentication.username)
        guard let agentID = UserDefaults.standard.string(forKey: key), !agentID.isEmpty else {
            throw HakoHTTPProxy.failure("请先在主应用“设置 → HTTP 代理”中选择 Agent。")
        }
        guard authentication.authenticated, !authentication.logoutPending else {
            throw HakoHTTPProxy.failure("HTTP 代理需要先登录 Sora 服务器。")
        }
        // Use the same server version policy as sign-in before forwarding any request.
        struct Version: Decodable { let serverVersion: String }
        let version = try JSONDecoder().decode(Version.self, from: await authentication.send(
            "/api/v1/version", method: "GET", body: nil, logSource: .hako)).serverVersion
        if let warning = HakoServerCompatibility.serverWarning(for: version) {
            throw HakoHTTPProxy.failure(warning)
        }
        try Task.checkCancellation()
        guard context == authentication.requestContext else { throw CancellationError() }
        let data = try await HakoHTTPProxyClient.send(agentID: agentID, parameters: parameters)
        guard context == authentication.requestContext else { throw CancellationError() }
        let reply = try JSONDecoder().decode(HakoHTTPProxy.Reply.self, from: data)
        if let error = reply.error { throw HakoHTTPProxy.failure("\(error.message)（\(error.code)）") }
        guard let result = reply.result, let url = request.url else { throw URLError(.badServerResponse) }
        let (body, response) = try result.unpack(for: url)
        try Task.checkCancellation()
        return (body, response)
    }
    override func stopLoading() {
        stateLock.lock()
        stopped = true
        let task = operation
        operation = nil
        stateLock.unlock()
        task?.cancel()
    }
}
