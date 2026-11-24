import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private actor UsageSignal {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func signal() {
        signalled = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
    func wait() async {
        if signalled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private final class UsageMockProtocol: URLProtocol, @unchecked Sendable {
    static let pendingStarted = UsageSignal()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url?.path == "/pending-search" {
            Task { await Self.pendingStarted.signal() }
            return
        }
        if request.url?.path == "/transport-cancel" {
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return
        }
        if request.url?.path == "/offline" {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        } else {
            let status = request.url?.path == "/limited" ? 429 : 200
            let body: String
            switch request.url?.path {
            case "/vendor-error": body = #"{"status":"error","code":429,"message":"limited"}"#
            case "/tushare-error": body = #"{"code":2002,"msg":"permission denied","data":null}"#
            case "/tushare-ok": body = #"{"code":0,"data":{"fields":[],"items":[]}}"#
            case "/malformed": body = "not JSON"
            default: body = #"{"values":[]}"#
            }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { }
}

@main struct MarketAPIUsageTests {
    static func request(_ host: String, _ path: String = "/") -> URLRequest {
        URLRequest(url: URL(string: "https://" + host + path)!)
    }
    static func main() async throws {
        await requestReasonsStayTaskLocal()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("usage.json")
        let usage = MarketAPIUsage(file: file)
        let now = Date(timeIntervalSince1970: 1_800_002_345)
        let currentHour = MarketAPIUsage.hour(now)
        await usage.record(request("api.tushare.pro"), outcome: .succeeded, at: currentHour.addingTimeInterval(-24 * 3600))
        await usage.record(request("api.tushare.pro"), outcome: .failed, at: currentHour.addingTimeInterval(-23 * 3600))
        await usage.record(request("api.tushare.pro"), outcome: .succeeded, at: now)
        await usage.record(request("api.twelvedata.com", "/quote?apikey=private-fixture"), outcome: .failed, at: now)
        await usage.record(request("api.twelvedata.com.evil.test"), outcome: .succeeded, at: now)
        await usage.record(request("example.test"), outcome: .failed, at: now)
        let first = try await usage.snapshot(for: .tushare, at: now)
        precondition(first.hours.count == 24 && first.total == 2 && first.hours.first?.count == 1 && first.hours.last?.count == 1)
        precondition(first.succeeded == 1 && first.failed == 1 && first.hours.first?.failed == 1 && first.hours.last?.succeeded == 1)
        precondition(first.hours.dropFirst().dropLast().allSatisfy { $0.count == 0 }, "No historical calls may be invented")
        let reopened = MarketAPIUsage(file: file)
        let twelve = try await reopened.snapshot(for: .twelveData, at: now)
        precondition(twelve.total == 1 && twelve.hours.last?.count == 1, "Both providers persist independently across restarts")
        precondition(twelve.succeeded == 0 && twelve.failed == 1, "Results must survive restart without guessing old totals")
        let content = try String(contentsOf: file, encoding: .utf8)
        precondition(!content.contains("apikey") && !content.contains("private-fixture") && !content.contains("https"), "Never persist credentials or URLs")
        let following = try await reopened.snapshot(for: .tushare, at: currentHour.addingTimeInterval(3600))
        precondition(following.total == 1 && following.hours.last?.count == 0, "Hour rollover removes the old bucket and includes the new empty hour")
        let tomorrow = try await reopened.snapshot(for: .tushare, at: currentHour.addingTimeInterval(24 * 3600))
        precondition(tomorrow.total == 0 && tomorrow.hours.count == 24)

        // Concurrent requests must never lose increments or double-count response handling.
        let concurrent = MarketAPIUsage(file: directory.appendingPathComponent("concurrent.json"))
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<40 { group.addTask { await concurrent.record(request("api.twelvedata.com"), outcome: i.isMultiple(of: 2) ? .succeeded : .failed, at: now) } }
        }
        let exact = try await concurrent.snapshot(for: .twelveData, at: now)
        precondition(exact.total == 40 && exact.succeeded == 20 && exact.failed == 20)
        await concurrent.record(request("api.twelvedata.com"), outcome: .failed, at: currentHour.addingTimeInterval(-3600))
        let outOfOrder = try await concurrent.snapshot(for: .twelveData, at: now)
        precondition(outOfOrder.total == 41 && outOfOrder.hours.last?.count == 40, "Late completion cannot erase a newer hour")
        await concurrent.record(request("api.twelvedata.com"), outcome: .failed, at: currentHour.addingTimeInterval(-24 * 3600))
        let afterExpired = try await concurrent.snapshot(for: .twelveData, at: now)
        precondition(afterExpired.total == 41, "Expired completion is not resurrected")

        // Test the real transport hook, without contacting providers or reading real keys.
        let network = MarketAPIUsage(file: directory.appendingPathComponent("network.json"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UsageMockProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        for path in ["/time_series", "/limited", "/offline", "/vendor-error", "/malformed"] {
            do { _ = try await HTTPTransport.data(for: request("api.twelvedata.com", path), using: session, marketUsage: network, marketGate: nil) }
            catch { precondition(path == "/offline") }
        }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await HTTPTransport.data(for: request("api.twelvedata.com"), using: session, marketUsage: network, marketGate: nil)
        }
        do { _ = try await cancelled.value; preconditionFailure("Pre-cancelled request must not be sent") }
        catch is CancellationError { }
        let calls = try await network.snapshot(for: .twelveData)
        precondition(calls.total == 5 && calls.succeeded == 1 && calls.failed == 4, "HTTP, transport, HTTP-200 business errors and malformed responses are failures; pre-cancelled work does not count")
        precondition(calls.failures.count == 4)
        precondition(calls.failures.contains { $0.httpStatus == 200 && $0.code == "429" && $0.message == "limited" }, "HTTP-200 business errors retain their provider message and code")
        precondition(calls.failures.contains { $0.httpStatus == 429 }, "Retain real HTTP status")
        precondition(calls.failures.contains { $0.httpStatus == nil && $0.code == "NSURLErrorDomain -1009" }, "Retain transport domain and error code without inventing HTTP status")
        precondition(calls.failures.contains { $0.message.contains("not JSON") }, "Malformed text responses remain diagnosable")
        let search = Task {
            try await HTTPTransport.data(for: request("api.twelvedata.com", "/pending-search"),
                                         using: session, marketUsage: network, marketGate: nil)
        }
        await UsageMockProtocol.pendingStarted.wait()
        search.cancel()
        do { _ = try await search.value; preconditionFailure("Cancelled search must not finish") }
        catch { precondition(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        let afterSearch = try await network.snapshot(for: .twelveData)
        precondition(afterSearch.total == calls.total && afterSearch.failures.count == calls.failures.count,
                     "Cancelling an in-flight search must not inflate failed calls or create network errors")
        do {
            _ = try await HTTPTransport.data(for: request("api.twelvedata.com", "/transport-cancel"),
                                             using: session, marketUsage: network, marketGate: nil)
            preconditionFailure("Unexplained transport cancellation must propagate")
        } catch { precondition((error as? URLError)?.code == .cancelled) }
        let transportFailure = try await network.snapshot(for: .twelveData)
        precondition(transportFailure.failed == calls.failed + 1 && transportFailure.failures.contains { $0.code == "NSURLErrorDomain -999" },
                     "Transport cancellation without a cancelled caller must remain diagnosable")
        for path in ["/tushare-ok", "/tushare-error"] {
            _ = try await HTTPTransport.data(for: request("api.tushare.pro", path), using: session, marketUsage: network, marketGate: nil)
        }
        let tushare = try await network.snapshot(for: .tushare)
        precondition(tushare.total == 2 && tushare.succeeded == 1 && tushare.failed == 1)
        precondition(tushare.failures.count == 1 && tushare.failures[0].code == "2002" && tushare.failures[0].message == "permission denied")
        precondition(tushare.failures.allSatisfy { $0.provider == .tushare })
        let quote = request("api.twelvedata.com", "/quote?symbol=AAPL&apikey=private-fixture")
        let http = HTTPURLResponse(url: quote.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        for body in [#"{"symbol":"AAPL","currency":"USD","close":"0"}"#,
                     #"{"symbol":"OTHER","currency":"USD","close":"181"}"#,
                     #"{"symbol":"AAPL","currency":"EUR","close":"181"}"#,
                     #"{"symbol":"AAPL","currency":"USD","close":"nan"}"#] {
            precondition(MarketAPIUsage.outcome(for: quote, response: http, data: Data(body.utf8)) == .failed)
        }
        precondition(MarketAPIUsage.outcome(for: quote, response: http, data: Data(#"{"symbol":"AAPL","currency":"USD","close":"181"}"#.utf8)) == .succeeded)
        try await failureDetailsPersistAndRedact(directory: directory, now: now)
        try await failureRetentionIsIndependent(directory: directory, now: now)
        print("Market API usage: successful/failed hourly results, 24-hour retention, persistence, provider isolation, concurrent/late completions, redaction, business errors and real transport hooks passed")
    }

    static func failureDetailsPersistAndRedact(directory: URL, now: Date) async throws {
        let file = directory.appendingPathComponent("details.json")
        let usage = MarketAPIUsage(file: file)
        let key = "private-twelve-key"
        let query = request("api.twelvedata.com", "/time_series?symbol=AAPL&apikey=" + key)
        let response = HTTPURLResponse(url: query.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let body = try JSONSerialization.data(withJSONObject: ["status": "error", "code": 429,
            "message": "Quota exceeded for \(key); API Key: unexpected-credential"])
        let detail = MarketAPIUsage.failureDetail(for: query, response: response, data: body)
        let traced = request("api.twelvedata.com", "/time_series?symbol=AAPL&mic_code=XNMS&exchange=NASDAQ&start_date=2026-11-10&end_date=2026-11-24&apikey=" + key)
        let trace = MarketAPIUsage.failureDetail(for: traced, response: response, data: body, reason: "新增关注报价校验")
        precondition(trace.message.contains("请求标的：AAPL") && trace.message.contains("2026-11-10 至 2026-11-24")
            && trace.message.contains("交易所 MIC：XNMS") && trace.message.contains("交易所：NASDAQ")
            && trace.message.contains("新增关注报价校验") && !trace.message.contains(key))
        await usage.record(query, outcome: .failed, failure: detail, at: now)
        var tushare = request("api.tushare.pro")
        tushare.httpMethod = "POST"
        tushare.httpBody = try JSONSerialization.data(withJSONObject: ["api_name": "trade_cal", "token": "private-tushare-token"])
        let payload = try JSONSerialization.data(withJSONObject: ["code": 2002, "msg": "无权访问，token=private-tushare-token"])
        let http = HTTPURLResponse(url: tushare.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        await usage.record(tushare, outcome: .failed,
            failure: MarketAPIUsage.failureDetail(for: tushare, response: http, data: payload), at: now.addingTimeInterval(1))
        let reopened = MarketAPIUsage(file: file)
        let td = try await reopened.snapshot(for: .twelveData, at: now)
        let ts = try await reopened.snapshot(for: .tushare, at: now)
        precondition(td.failures.count == 1 && ts.failures.count == 1)
        precondition(td.failures[0].endpoint == "/time_series" && td.failures[0].httpStatus == 200 && td.failures[0].code == "429")
        precondition(td.failures[0].title == "请求频率超限")
        precondition(ts.failures[0].endpoint == "trade_cal" && ts.failures[0].code == "2002")
        precondition(ts.failures[0].diagnosticText.contains("Tushare Pro") && ts.failures[0].diagnosticText.contains("错误码：2002"))
        let stored = try String(contentsOf: file.deletingPathExtension().appendingPathExtension("failures.json"), encoding: .utf8)
        for secret in [key, "private-tushare-token", "unexpected-credential", "https://"] {
            precondition(!stored.contains(secret), "Failure storage must not retain credential text or request URLs")
            precondition(!td.failures[0].diagnosticText.contains(secret) && !ts.failures[0].diagnosticText.contains(secret))
        }
        let expired = try await reopened.snapshot(for: .tushare, at: now.addingTimeInterval(24 * 3600))
        precondition(expired.failures.isEmpty, "Expired failure details are removed after restart too")
    }

    static func requestReasonsStayTaskLocal() async {
        precondition(MarketAPIRequestContext.reason == nil)
        await withTaskGroup(of: Bool.self) { group in
            for reason in ["持仓价格走势图", "历史汇率补数"] {
                group.addTask {
                    await MarketAPIRequestContext.$reason.withValue(reason) {
                        await Task.yield()
                        let inherited = await Task { MarketAPIRequestContext.reason }.value
                        let detached = await Task.detached { MarketAPIRequestContext.reason }.value
                        return inherited == reason && detached == nil && MarketAPIRequestContext.reason == reason
                    }
                }
            }
            for await isolated in group {
                precondition(isolated, "Concurrent requests isolate their diagnostic reasons; child tasks inherit them")
            }
        }
        precondition(MarketAPIRequestContext.reason == nil, "Request context must not leak after its scope ends")
    }

    static func failureRetentionIsIndependent(directory: URL, now: Date) async throws {
        let usage = MarketAPIUsage(file: directory.appendingPathComponent("limits.json"))
        await usage.record(request("api.tushare.pro"), outcome: .failed, at: now)
        for offset in 0...MarketAPIUsage.failureLimit {
            await usage.record(request("api.twelvedata.com", "/quote"), outcome: .failed,
                at: now.addingTimeInterval(Double(offset + 1)))
        }
        let time = now.addingTimeInterval(Double(MarketAPIUsage.failureLimit + 1))
        let td = try await usage.snapshot(for: .twelveData, at: time)
        let ts = try await usage.snapshot(for: .tushare, at: time)
        precondition(td.failed == MarketAPIUsage.failureLimit + 1 && td.failures.count == MarketAPIUsage.failureLimit)
        precondition(td.failures.first!.time > td.failures.last!.time, "Details are newest first")
        precondition(ts.failures.count == 1, "Twelve Data activity must not evict Tushare details")
        let blocked = directory.appendingPathComponent("blocked")
        try Data().write(to: blocked)
        let failingStorage = MarketAPIUsage(file: blocked.appendingPathComponent("usage.json"))
        await failingStorage.record(request("api.tushare.pro"), outcome: .failed, at: now)
        let unsaved = try await failingStorage.snapshot(for: .tushare, at: now)
        precondition(unsaved.persistenceFailed && unsaved.failed == 1 && unsaved.failures.count == 1,
                     "Storage failures retain in-memory details and never interrupt market requests")
    }
}
