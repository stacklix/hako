import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class GateClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_800_000_000)
    private var pauses: [TimeInterval] = []
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; pauses.append(seconds); date.addTimeInterval(seconds) }
    func waits() -> [TimeInterval] { lock.lock(); defer { lock.unlock() }; return pauses }
}

private actor GateCalls {
    var count = 0
    func sent() { count += 1 }
}

private final class GateHTTPProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let limited = request.url?.path == "/limited"
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: limited ? 429 : 200,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((limited ? #"{"code":429,"message":"limited"}"# : #"{"values":[]}"#).utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@main struct MarketAPIRequestGateTests {
    static func request(_ key: String, path: String) -> URLRequest {
        URLRequest(url: URL(string: "https://api.twelvedata.com/" + path + "?apikey=" + key)!)
    }
    static func reply(_ request: URLRequest, status: Int = 200, body: String = "{}") -> MarketAPIRequestGate.Response {
        (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    static func main() async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        for status in [429, 200] {
            let clock = GateClock()
            let gate = MarketAPIRequestGate(now: { clock.now() }, sleep: { clock.advance($0) })
            let first = request("key-a", path: "time_series"), next = request("key-a", path: "symbol_search")
            _ = try await gate.data(for: first, session: session) { reply(first, status: status, body: #"{"code":429}"#) }
            _ = try await gate.data(for: next, session: session) { reply(next) }
            precondition(clock.waits() == [60], "HTTP and HTTP-200 business 429 must pause every endpoint for exactly 60 seconds")
        }
        do {
            let clock = GateClock()
            let gate = MarketAPIRequestGate(now: { clock.now() }, sleep: { clock.advance($0) })
            let first = request("key-a", path: "time_series"), other = request("key-b", path: "quote")
            _ = try await gate.data(for: first, session: session) { reply(first, status: 429) }
            _ = try await gate.data(for: other, session: session) { reply(other) }
            precondition(clock.waits().isEmpty, "Independent credentials do not block each other")
            let retry = request("key-a", path: "quote")
            _ = try await gate.data(for: retry, session: session) { reply(retry, status: 429) }
            _ = try await gate.data(for: first, session: session) { reply(first) }
            precondition(clock.waits() == [60, 60], "A new 429 starts a new full minute")
        }
        do {
            let clock = GateClock()
            let gate = MarketAPIRequestGate(defaultLimit: 2, now: { clock.now() }, sleep: { clock.advance($0) })
            for path in ["quote", "symbol_search", "time_series"] {
                let query = request("budget-key", path: path)
                _ = try await gate.data(for: query, session: session) { reply(query) }
            }
            precondition(clock.waits() == [60], "All endpoints share the same proactive credit budget")
        }
        do {
            let clock = GateClock()
            let gate = MarketAPIRequestGate(now: { clock.now() }, sleep: { clock.advance($0) })
            var first = URLRequest(url: URL(string: "https://api.tushare.pro/")!)
            first.httpMethod = "POST"
            first.httpBody = Data(#"{"token":"tushare-key","api_name":"daily"}"#.utf8)
            var next = first
            next.httpBody = Data(#"{"token":"tushare-key","api_name":"trade_cal"}"#.utf8)
            let a = first, b = next
            _ = try await gate.data(for: a, session: session) { reply(a, status: 429) }
            _ = try await gate.data(for: b, session: session) { reply(b) }
            precondition(clock.waits() == [60], "Tushare endpoints share the token cooldown too")
        }
        do {
            let clock = GateClock()
            let gate = MarketAPIRequestGate(now: { clock.now() }, sleep: { clock.advance($0) })
            let first = request("same-key", path: "time_series")
            var header = URLRequest(url: URL(string: "https://api.twelvedata.com/quote")!)
            header.setValue("apikey same-key", forHTTPHeaderField: "Authorization")
            let next = header
            _ = try await gate.data(for: first, session: session) { reply(first, status: 429) }
            _ = try await gate.data(for: next, session: session) { reply(next) }
            precondition(clock.waits() == [60], "Query and header authentication share the same key queue")
        }
        do {
            let clock = GateClock()
            let gate = MarketAPIRequestGate(defaultLimit: 2, now: { clock.now() }, sleep: { clock.advance($0) })
            for path in ["quote", "symbol_search", "time_series"] {
                let query = request("higher-plan", path: path)
                _ = try await gate.data(for: query, session: session) {
                    (Data("{}".utf8), HTTPURLResponse(url: query.url!, statusCode: 200, httpVersion: nil,
                        headerFields: ["api-credits-used": "1", "api-credits-left": "9"])!)
                }
            }
            precondition(clock.waits().isEmpty, "Response headers update the plan budget instead of hardcoding the Basic limit")
        }
        do {
            let clock = GateClock()
            let gate = MarketAPIRequestGate(now: { clock.now() }, sleep: { clock.advance($0) })
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("usage.json")
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            let usage = MarketAPIUsage(file: file)
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [GateHTTPProtocol.self]
            let mock = URLSession(configuration: config)
            defer { mock.invalidateAndCancel() }
            _ = try await HTTPTransport.data(for: request("transport-key", path: "limited"), using: mock, marketUsage: usage, marketGate: gate)
            _ = try await HTTPTransport.data(for: request("transport-key", path: "time_series"), using: mock, marketUsage: usage, marketGate: gate)
            let snapshot = try await usage.snapshot(for: .twelveData)
            precondition(clock.waits() == [60] && snapshot.total == 2 && snapshot.succeeded == 1 && snapshot.failed == 1,
                         "Real transport calls use the gate; cooldown waits never count as provider requests")
        }
        do {
            let gate = MarketAPIRequestGate()
            let calls = GateCalls(), query = request("dedup-key", path: "time_series")
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<12 {
                    group.addTask {
                        _ = try await gate.data(for: query, session: session) {
                            await calls.sent()
                            try await Task.sleep(for: .milliseconds(30))
                            return reply(query)
                        }
                    }
                }
                try await group.waitForAll()
            }
            let count = await calls.count
            precondition(count == 1, "Concurrent identical reads use one physical request")
        }
        do {
            let gate = MarketAPIRequestGate()
            let calls = GateCalls(), query = request("cancel-key", path: "time_series")
            let operation: @Sendable () async throws -> MarketAPIRequestGate.Response = {
                await calls.sent()
                try await Task.sleep(for: .milliseconds(100))
                return reply(query)
            }
            let first = Task { try await gate.data(for: query, session: session, send: operation) }
            let second = Task { try await gate.data(for: query, session: session, send: operation) }
            try await Task.sleep(for: .milliseconds(20))
            first.cancel()
            do { _ = try await first.value; preconditionFailure("Cancelled waiter must return promptly") }
            catch is CancellationError { }
            _ = try await second.value
            let count = await calls.count
            precondition(count == 1, "Cancelling one consumer does not cancel another consumer's shared request")
        }
        do {
            let gate = MarketAPIRequestGate()
            let first = request("paused-key", path: "time_series"), next = request("paused-key", path: "quote")
            _ = try await gate.data(for: first, session: session) { reply(first, status: 429) }
            let queued = Task { try await gate.data(for: next, session: session) { preconditionFailure("Cancelled queued request must never be sent") } }
            try await Task.sleep(for: .milliseconds(20))
            queued.cancel()
            do { _ = try await queued.value; preconditionFailure("Cancelled queue waiter must not wait for the minute") }
            catch is CancellationError { }
        }
        print("Market request gate: exact 60-second HTTP/business-429 cooldown, key isolation, repeated cooldowns, shared endpoint budget, Tushare, coalescing and cancellation passed")
    }
}
