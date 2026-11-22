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
        let task = Task { @MainActor [self] in
            do {
                let parameters = try HakoHTTPProxy.parameters(request)
                let authentication = AuthenticatedServerService.shared
                let context = authentication.requestContext
                let key = HakoHTTPProxy.settingsKey(server: authentication.serverURL, account: authentication.username)
                guard let agentID = UserDefaults.standard.string(forKey: key), !agentID.isEmpty else {
                    throw HakoHTTPProxy.failure("请先在主应用“设置 → HTTP 代理”中选择 Agent。")
                }
                guard authentication.authenticated, !authentication.logoutPending else {
                    throw HakoHTTPProxy.failure("HTTP 代理需要先登录 Sora 服务器。")
                }
                // Require the larger opaque relay envelope before sending a mutating request.
                struct Version: Decodable { let serverVersion: String }
                let version = try JSONDecoder().decode(Version.self, from: await authentication.send(
                    "/api/v1/version", method: "GET", body: nil, logSource: .hako)).serverVersion
                let parts = version.split(separator: ".").compactMap { Int($0) }
                guard parts.count == 3, parts[0] == 0, parts[1] == 8, parts[2] >= 15 else {
                    throw HakoHTTPProxy.failure("HTTP 代理要求 Sora 0.8.15 或更高的 0.8.x 版本。")
                }
                try Task.checkCancellation()
                guard context == authentication.requestContext else { throw CancellationError() }
                let escaped = agentID.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
                let data = try await authentication.send("/api/v1/agents/\(escaped)/requests", method: "POST",
                    body: ["method": HakoHTTPProxy.command, "version": 1, "params": parameters], logSource: .hako)
                guard context == authentication.requestContext else { throw CancellationError() }
                let reply = try JSONDecoder().decode(HakoHTTPProxy.Reply.self, from: data)
                if let error = reply.error { throw HakoHTTPProxy.failure("\(error.message)（\(error.code)）") }
                guard let result = reply.result, let url = request.url else { throw URLError(.badServerResponse) }
                let (body, response) = try result.unpack(for: url)
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
    override func stopLoading() {
        stateLock.lock()
        stopped = true
        let task = operation
        operation = nil
        stateLock.unlock()
        task?.cancel()
    }
}
