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

private actor GateConcurrency {
    var active = 0
    var maximum = 0
    var started = 0
    var released = false
    var timedOut = false
    var starts: [CheckedContinuation<Void, Never>] = []
    var responses: [CheckedContinuation<Void, Never>] = []
    func enter() async {
        active += 1; started += 1; maximum = max(maximum, active)
        if started == 3 { starts.forEach { $0.resume() }; starts.removeAll() }
        if !released { await withCheckedContinuation { responses.append($0) } }
    }
    func leave() { active -= 1 }
    func waitForThree() async {
        if started < 3 { await withCheckedContinuation { starts.append($0) } }
    }
    func release(timedOut: Bool = false) {
        self.timedOut = timedOut; released = true
        starts.forEach { $0.resume() }; starts.removeAll()
        responses.forEach { $0.resume() }; responses.removeAll()
    }
}

private actor GateResponseLatch {
    private var started = false
    private var released = false
    private var starts: [CheckedContinuation<Void, Never>] = []
    private var responses: [CheckedContinuation<Void, Never>] = []
    private(set) var timedOut = false

    func block() async {
        started = true
        starts.forEach { $0.resume() }; starts.removeAll()
        if !released { await withCheckedContinuation { responses.append($0) } }
    }
    func waitForStart() async {
        if !started { await withCheckedContinuation { starts.append($0) } }
    }
    func release(timedOut: Bool = false) {
        self.timedOut = self.timedOut || timedOut
        released = true
        responses.forEach { $0.resume() }; responses.removeAll()
    }
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
        do {
            let clock = GateClock()
            let gate = MarketAPIRequestGate(now: { clock.now() }, sleep: { clock.advance($0) })
            func tushare(_ api: String, key: String = "hk-key") throws -> URLRequest {
                var query = URLRequest(url: URL(string: "https://api.tushare.pro/")!)
                query.httpMethod = "POST"
                query.httpBody = try JSONSerialization.data(withJSONObject: ["api_name": api, "token": key])
                return query
            }
            let daily = try tushare("hk_daily"), live = try tushare("rt_hk_k"), mainland = try tushare("daily")
            _ = try await gate.data(for: daily, session: session) { reply(daily) }
            _ = try await gate.data(for: live, session: session) { reply(live) }
            _ = try await gate.data(for: mainland, session: session) { reply(mainland) }
            let other = try tushare("hk_daily", key: "other-key")
            _ = try await gate.data(for: other, session: session) { reply(other) }
            precondition(clock.waits().isEmpty, "HK history budget must not slow other APIs or credentials")
            _ = try await gate.data(for: daily, session: session) { reply(daily, body: #"{"code":40203}"#) }
            precondition(clock.waits() == [61], "HK historical reads must be at least one minute apart")
            _ = try await gate.data(for: live, session: session) { reply(live) }
            precondition(clock.waits() == [61], "HK history cooldown must leave live quotes available")
        }
        do {
            let gate = MarketAPIRequestGate()
            let channels = [GateConcurrency(), GateConcurrency(), GateConcurrency()]
            let reads = Task {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for channel in 0..<3 {
                        let probe = channels[channel]
                        for index in 0..<6 {
                            let host = channel == 0 ? "api.twelvedata.com" : channel == 1
                                ? (index.isMultiple(of: 2) ? "push2his.eastmoney.com" : "api.fund.eastmoney.com")
                                : (index.isMultiple(of: 2) ? "data-api.binance.vision" : "www.binance.com")
                            let query = URLRequest(url: URL(string: "https://\(host)/quote/\(index)?apikey=channel-key-\(index % 2)")!)
                            group.addTask {
                                _ = try await gate.data(for: query, session: session) {
                                    await probe.enter()
                                    await probe.leave()
                                    return reply(query)
                                }
                            }
                        }
                    }
                    try await group.waitForAll()
                }
            }
            let watchdog = Task {
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled { for probe in channels { await probe.release(timedOut: true) } }
            }
            for probe in channels { await probe.waitForThree() }
            var active = 0
            for probe in channels {
                let (started, timedOut, running) = await (probe.started, probe.timedOut, probe.active)
                precondition(started == 3 && !timedOut, "A blocked channel must not consume another channel's slots")
                active += running
            }
            precondition(active == 9, "Three channels can each have three physical requests in flight")
            for probe in channels { await probe.release() }
            watchdog.cancel(); try await reads.value
            for probe in channels {
                let (maximum, total) = await (probe.maximum, probe.started)
                precondition(maximum == 3 && total == 6, "Subdomains and credentials must share their channel concurrency limit")
            }
            precondition(MarketAPIChannel.matching("api.coinbase.com") == .coinbase)
            precondition(MarketAPIChannel.matching("data-api.ecb.europa.eu") == .ecb)
            precondition(MarketAPIChannel.matching("eastmoney.com.example.org") == nil)
        }
        do {
            let gate = MarketAPIRequestGate()
            let probe = GateConcurrency()
            let reads = Task {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for index in 0..<7 {
                        group.addTask {
                            let query = request("parallel-key", path: "quote/\(index)")
                            _ = try await gate.data(for: query, session: session) {
                                await probe.enter()
                                await probe.leave()
                                return reply(query)
                            }
                        }
                    }
                    try await group.waitForAll()
                }
            }
            let watchdog = Task {
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled { await probe.release(timedOut: true) }
            }
            await probe.waitForThree()
            let (started, timedOut) = await (probe.started, probe.timedOut)
            precondition(started == 3 && !timedOut, "One credential must allow three overlapping physical reads")
            await probe.release(); watchdog.cancel()
            try await reads.value
            let (maximum, total) = await (probe.maximum, probe.started)
            precondition(maximum == 3 && total == 7, "The shared gate must never exceed three physical requests")
        }
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
            let publicLimited = URLRequest(url: URL(string: "https://push2his.eastmoney.com/limited")!)
            let publicNext = URLRequest(url: URL(string: "https://api.fund.eastmoney.com/nav")!)
            _ = try await HTTPTransport.data(for: publicLimited, using: mock, marketUsage: usage, marketGate: gate)
            let independent = request("transport-key", path: "quote")
            _ = try await HTTPTransport.data(for: independent, using: mock, marketUsage: usage, marketGate: gate)
            precondition(clock.waits() == [60], "A public channel cooldown must not block Twelve Data")
            _ = try await HTTPTransport.data(for: publicNext, using: mock, marketUsage: usage, marketGate: gate)
            precondition(clock.waits() == [60, 60], "Public sources must use the transport gate across their subdomains")
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
            let latch = GateResponseLatch()
            let operation: @Sendable () async throws -> MarketAPIRequestGate.Response = {
                await calls.sent()
                await latch.block()
                try Task.checkCancellation()
                return reply(query)
            }
            let first = Task { try await gate.data(for: query, session: session, send: operation) }
            let second = Task { try await gate.data(for: query, session: session, send: operation) }
            await latch.waitForStart()
            // Keep the physical response blocked until the cancelled caller has
            // returned. Runner scheduling cannot make a response win a sleep race.
            let watchdog = Task {
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled { await latch.release(timedOut: true) }
            }
            first.cancel()
            do { _ = try await first.value; preconditionFailure("Cancelled waiter must return promptly") }
            catch is CancellationError { }
            watchdog.cancel()
            let timedOut = await latch.timedOut
            precondition(!timedOut, "Cancelled waiter must return before releasing the physical response")
            await latch.release()
            _ = try await second.value
            let count = await calls.count
            precondition(count == 1, "Cancelling one consumer does not cancel another consumer's shared request")
        }
        do {
            let latch = GateResponseLatch()
            let gate = MarketAPIRequestGate(sleep: { _ in await latch.block(); try Task.checkCancellation() })
            let first = request("paused-key", path: "time_series"), next = request("paused-key", path: "quote")
            _ = try await gate.data(for: first, session: session) { reply(first, status: 429) }
            let queued = Task { try await gate.data(for: next, session: session) { preconditionFailure("Cancelled queued request must never be sent") } }
            await latch.waitForStart()
            let watchdog = Task {
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled { await latch.release(timedOut: true) }
            }
            queued.cancel()
            do { _ = try await queued.value; preconditionFailure("Cancelled queue waiter must not wait for the minute") }
            catch is CancellationError { }
            watchdog.cancel()
            let timedOut = await latch.timedOut
            precondition(!timedOut, "Cancelled cooldown waiter must return while the shared cooldown is still blocked")
            await latch.release()
        }
        print("Market request gate: three concurrent reads, exact 60-second HTTP/business-429 cooldown, key isolation, repeated cooldowns, shared endpoint budget, Tushare, coalescing and cancellation passed")
    }
}
