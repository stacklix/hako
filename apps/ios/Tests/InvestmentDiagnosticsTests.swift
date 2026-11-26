import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class InvestmentHTTPMock: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"error":"invalid_request","token":"response-secret"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@MainActor private final class ForwardedEvents {
    var events: [HakoExecutionEvent] = []
    func append(_ event: HakoExecutionEvent) { events.append(event) }
}

@main struct InvestmentDiagnosticsTests {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("investment-logs-\(UUID())")
        let file = directory.appendingPathComponent("events.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HakoLogStore(fileURL: file)
        let forwarded = ForwardedEvents()
        try await HakoExecutionDiagnostics.context.withValue({ forwarded.append($0) }) {
            try await InvestmentDiagnostics.run("进入投资记账", store: store) {
                try await InvestmentDiagnostics.run("读取缓存", store: store) {
                    try await Task.sleep(for: .milliseconds(1))
                    HakoExecutionDiagnostics.record("缓存命中", detail: "报价 3 条；API Key=hidden-key")
                }
                try await InvestmentDiagnostics.run("独立自动快照", independent: true, store: store) {
                    try await Task.sleep(for: .milliseconds(1))
                    HakoExecutionDiagnostics.record("账户月批", detail: "账户 A；2026-11-01 至 2026-11-25；25 行")
                }
            }
        }
        store.flush()
        let first = store.snapshot().entries
        precondition(first.allSatisfy { $0.source == .investment })
        precondition(first.count == forwarded.events.count, "Nested independent runs must forward each event once, without duplicate persistence")
        precondition(first.filter { $0.message == "读取缓存 · 完成" }.first?.detail.contains("耗时：") == true)
        precondition(!first.map(\.text).joined().contains("hidden-key"))
        let entry = first.first { $0.message == "进入投资记账 · 开始" }!
        let nested = first.first { $0.message == "读取缓存 · 开始" }!
        let independent = first.first { $0.message == "独立自动快照 · 开始" }!
        precondition(runID(entry) == runID(nested) && runID(entry) != runID(independent))
        precondition(InvestmentDiagnostics.current.get() == nil && HakoExecutionDiagnostics.context.get() == nil)
        precondition(HTTPTransport.logSource.get() == nil && HTTPTransport.logContext.get() == nil)

        // Interleaving tasks must retain distinct identities even after suspension.
        let left = Task { @MainActor in
            await InvestmentDiagnostics.run("左任务", store: store) {
                await Task.yield()
                HakoExecutionDiagnostics.record("左任务详情")
            }
        }
        let right = Task { @MainActor in
            await InvestmentDiagnostics.run("右任务", store: store) {
                await Task.yield()
                HakoExecutionDiagnostics.record("右任务详情")
            }
        }
        await left.value; await right.value
        let concurrent = store.snapshot().entries
        let leftStart = concurrent.first { $0.message == "左任务 · 开始" }!
        let rightStart = concurrent.first { $0.message == "右任务 · 开始" }!
        precondition(runID(leftStart) != runID(rightStart))
        precondition(runID(leftStart) == runID(concurrent.first { $0.message == "左任务详情 · 信息" }!))
        precondition(runID(rightStart) == runID(concurrent.first { $0.message == "右任务详情 · 信息" }!))

        do {
            try await InvestmentDiagnostics.run("提交失败", store: store) {
                throw NSError(domain: "HTTP", code: 400, userInfo: [NSLocalizedDescriptionKey: "invalid_request; token=private-token"])
            }
            preconditionFailure("Failure was swallowed")
        } catch { }
        do {
            try await InvestmentDiagnostics.run("取消快照", store: store) { throw CancellationError() }
            preconditionFailure("Cancellation was swallowed")
        } catch is CancellationError { }
        let completed = store.snapshot().entries
        precondition(completed.first { $0.message == "提交失败 · 失败" }?.level == .error)
        precondition(completed.first { $0.message == "取消快照 · 已取消" }?.level == .warning)
        precondition(!completed.map(\.text).joined().contains("private-token"))
        let exported = HakoLogExport.text(title: "投资运行日志", entries: completed, version: "0.9.4")
        precondition(exported.contains("提交失败") && exported.contains("取消快照") && exported.contains("耗时："))
        precondition(exported.contains("不受当前筛选影响")
                     && exported.range(of: #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z"#, options: .regularExpression) != nil,
                     "Export includes all retained events and precise timestamps")
        store.flush()
        precondition(HakoLogStore(fileURL: file).snapshot().entries.count == completed.count)
        store.append(source: .hako, level: .info, message: "其他模块保留")
        store.clear(source: .investment)
        precondition(store.snapshot().entries.map(\.message) == ["其他模块保留"])
        precondition(HakoLogStore(fileURL: file).snapshot().entries.map(\.message) == ["其他模块保留"])

        try await checkHTTPContext()
        print("Investment diagnostics: persistence, redaction, nested and concurrent scopes, Shortcut forwarding, HTTP status/size and scoped clear passed")
    }

    private static func runID(_ entry: HakoLogEntry) -> Substring { entry.detail.split(separator: "\n").first! }

    @MainActor private static func checkHTTPContext() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [InvestmentHTTPMock.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://example.test/investment/changes?token=query-secret")!)
        request.httpMethod = "POST"
        request.httpBody = Data(repeating: 65, count: 20_000)
        request.setValue("Bearer request-secret", forHTTPHeaderField: "Authorization")
        try await InvestmentDiagnostics.run("提交 HTTP 请求") {
            _ = try await HTTPTransport.data(for: request, using: session, logBody: false)
        }
        let http = HakoLogStore.shared.snapshot().entries.first { $0.message == "HTTP POST · 400" }!
        precondition(http.source == .investment && http.level == .error)
        for value in ["投资运行 ID：", "20000 字节", "HTTP 状态：400", "耗时："] {
            precondition(http.detail.contains(value), "Missing diagnostic field: \(value)")
        }
        for secret in ["query-secret", "request-secret", "response-secret", String(repeating: "A", count: 100)] {
            precondition(!http.detail.contains(secret))
        }
        request.httpBody = Data(#"{"token":"body-secret"}"#.utf8)
        try await InvestmentDiagnostics.run("提交小型 HTTP 请求") {
            _ = try await HTTPTransport.data(for: request, using: session)
        }
        let response = HakoLogStore.shared.snapshot().entries.first { $0.message == "HTTP POST · 400" }!
        precondition(response.detail.contains("invalid_request") && !response.detail.contains("body-secret") && !response.detail.contains("response-secret"))
        _ = try await HTTPTransport.data(for: URLRequest(url: URL(string: "https://example.test/outside")!), using: session)
        let outside = HakoLogStore.shared.snapshot().entries.first { $0.message == "HTTP GET · 400" }!
        precondition(outside.source == .hako && !outside.detail.contains("投资运行 ID："), "Task-local HTTP scope must restore after operation")
    }
}
