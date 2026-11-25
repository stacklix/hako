import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private actor StockTradeRequestSignal {
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func signal() {
        started = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
    func wait() async {
        if started { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private final class StockTradeRequestProtocol: URLProtocol {
    static let pending = StockTradeRequestSignal()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        switch request.url!.lastPathComponent {
        case "pending": Task { await Self.pending.signal() }; return
        case "transport-cancel": client?.urlProtocol(self, didFailWithError: URLError(.cancelled)); return
        case "offline": client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return
        case "timeout": client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return
        default: break
        }
        let failed = request.url!.lastPathComponent == "unavailable"
        let response = HTTPURLResponse(url: request.url!, statusCode: failed ? 503 : 200, httpVersion: nil, headerFields: nil)!
        let body = failed ? #"{"code":"monitor_unavailable","message":"private upstream detail","requestId":"test","retryable":true}"# : #"{"items":[]}"#
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@main struct StockTradeRoutingTests {
    static func main() async throws {
        let roots = ["https://example.com", "https://example.com/"]
        let bases = roots + ["https://example.com/cerno", "https://example.com/cerno/", "https://example.com/apps/cerno/"]
        let endpoints = [["meta"], ["auth", "native", "start"], ["auth", "native", "complete"], ["auth", "session"], ["selection", "latest"], ["stocks", "600519.SH", "bars"], ["alerts"]]
        for base in bases {
            let connection = try StockTradeConnection(origin: base, clientID: "app_cerno").normalized()
            let client = try StockTradeClient(connection: connection)
            precondition(connection.applicationOrigin == "https://example.com")
            for endpoint in endpoints {
                let request = try client.request(endpoint, query: [.init(name: "cursor", value: "a/b?x=y")], token: "application-token")
                let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                let prefix = URLComponents(string: connection.origin)!.path
                precondition(components.path == prefix + "/api/v1/" + endpoint.joined(separator: "/"), "Base path must cover every endpoint")
                precondition(components.host == "example.com" && components.queryItems == [.init(name: "cursor", value: "a/b?x=y")])
                precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer application-token")
                for header in ["Origin", "Sec-Fetch-Site", "X-Proxy", "Cookie"] { precondition(request.value(forHTTPHeaderField: header) == nil) }
            }
        }
        let encoded = try StockTradeConnection(origin: " HTTPS://EXAMPLE.COM:443/%63erno/ ", clientID: " app ").normalized()
        precondition(encoded.origin == "https://example.com/cerno" && encoded.clientID == "app")
        let nested = try StockTradeConnection(origin: "https://example.com/apps/cerno/", clientID: "app").normalized()
        precondition(nested.applicationOrigin == "https://example.com")
        let unicode = try StockTradeConnection(origin: "https://example.com/选股/", clientID: "app").normalized()
        let canonicalUnicode = try StockTradeConnection(origin: unicode.origin, clientID: "app").normalized()
        precondition(unicode == canonicalUnicode)
        let client = try StockTradeClient(connection: nested)
        for endpoint in [["..", "auth"], ["."], ["//other.example"], ["a/b"], ["a\\b"]] {
            do { _ = try client.request(endpoint); preconditionFailure("Unsafe endpoint accepted") }
            catch StockTradeFailure.configuration { }
        }
        for bad in ["http://example.com/cerno", "https://user:secret@example.com/cerno", "https://example.com/cerno?token=secret", "https://example.com/cerno#fragment",
                    "https://example.com/../other", "https://example.com/cerno/./other", "https://example.com/%2e%2e/other", "https://example.com/cerno%2fother", "https://example.com/cerno%5cother",
                    "https://example.com/cerno/%252e%252e", "https://example.com/cerno//other", "https://example.com/cerno/%00", "https://example.com/cerno/%7f", "https://example.com/cerno/%3Ftoken", "https://example.com/cerno\\other"] {
            precondition(StockTradeConnection.httpsBaseURL(bad) == nil, "Ambiguous or unsafe base address accepted: \(bad)")
        }
        try await cancelledRequestsDoNotBecomeViewErrors()
        print("Cerno routing, caller cancellation, visible transport interruptions and unchanged network/API failures passed")
    }

    static func cancelledRequestsDoNotBecomeViewErrors() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StockTradeRequestProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = try StockTradeClient(connection: .init(origin: "https://cerno.test", clientID: "test"), session: session)
        let pending = Task { try await client.data(["pending"]) }
        await StockTradeRequestProtocol.pending.wait()
        pending.cancel()
        do { _ = try await pending.value; preconditionFailure("Cancelled request returned data") }
        catch is CancellationError { }

        do { _ = try await client.data(["transport-cancel"]); preconditionFailure("Unexplained interruption was hidden") }
        catch StockTradeFailure.requestInterrupted {
            precondition(StockTradeFailure.requestInterrupted.localizedDescription.contains("请求意外中断"))
        }
        for (path, code) in [("offline", URLError.Code.notConnectedToInternet), ("timeout", .timedOut)] {
            do { _ = try await client.data([path]); preconditionFailure("Network failure was hidden") }
            catch let error as URLError { precondition(error.code == code) }
        }
        do { _ = try await client.data(["unavailable"]); preconditionFailure("API failure was hidden") }
        catch StockTradeFailure.api(let status, let code, _, _) {
            precondition(status == 503 && code == "monitor_unavailable")
        }
        let data = try await client.data(["ok"])
        precondition(String(decoding: data, as: UTF8.self) == #"{"items":[]}"#, "Cancellation prevented a later refresh")
    }
}
