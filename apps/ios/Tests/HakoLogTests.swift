import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class HTTPLogMockProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        if url.path == "/offline" {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: url.path == "/restricted" ? 451 : 201, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": "application/json", "X-Trace": "http-log-regression", "Set-Cookie": "session=private-cookie; Path=/"
        ])!
        let data = Data(#"{"result":"visible-result","refreshToken":"private-refresh","echo":"private-cookie private-dpop"}"#.utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@main struct HakoLogTests {
    static func main() async throws {
        let direct = HTTPTransport.makeSession(useSystemProxy: false)
        let system = HTTPTransport.makeSession()
        precondition(direct.configuration.connectionProxyDictionary?.isEmpty == true,
                     "LAN sessions must explicitly bypass the system HTTP/PAC proxy")
        precondition(system.configuration.connectionProxyDictionary == nil,
                     "Cloud sessions must retain the system proxy policy")
        direct.invalidateAndCancel(); system.invalidateAndCancel()
        try await checkHTTPLogs()
        // Exercise both public call shapes: an unlabeled middle default argument
        // cannot be omitted when the following argument is also unlabeled.
        HakoLog.record(.hako, "default-level regression", detail: "safe detail")
        HakoLog.record(.hako, .warning, "explicit-level regression")
        let calls = HakoLogStore.shared.snapshot().entries
        precondition(calls.contains { $0.message == "default-level regression" && $0.level == .info })
        precondition(calls.contains { $0.message == "explicit-level regression" && $0.level == .warning })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hako-log-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await checkHangDiagnostics(at: root.appendingPathComponent("hangs.json"))
        let file = root.appendingPathComponent("events.json")
        let store = HakoLogStore(fileURL: file)

        // Preserve precisely the endpoint fields needed to diagnose the Aliyun rejection.
        let raw = "wss://name:password@cn-chengdu.axt.aliyuncs.com:443/session?sessionId=s-private&token=private-token&newCredential=unknown-secret#fragment-secret"
        let safe = HakoLog.safeURL(raw)
        precondition(safe.contains("cn-chengdu.axt.aliyuncs.com:443/session"))
        for secret in ["name", "password", "s-private", "private-token", "unknown-secret", "fragment-secret"] {
            precondition(!safe.contains(secret))
        }
        store.append(source: .cloudServers, level: .info, message: "阿里云返回终端连接地址", detail: safe)
        store.append(source: .containers, level: .error, message: "API Key=private-key", detail: "Bearer private-bearer\nAccessKeySecret=private-ak\n?token=private-query&other=private-other")
        store.append(source: .devices, level: .warning, message: "已知凭据", detail: "raw+secret raw%2Bsecret", secrets: ["raw+secret"])
        store.flush()
        let saved = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        for secret in ["private-key", "private-bearer", "private-ak", "private-query", "private-other", "raw+secret", "raw%2Bsecret"] {
            precondition(!saved.contains(secret))
        }
        let restored = HakoLogStore(fileURL: file).snapshot().entries
        precondition(restored.count == 3 && restored[0].source == .devices && restored[2].source == .cloudServers)
        precondition(restored[2].detail.contains(":443/session"))
        store.append(source: .crypto, level: .info, message: "资产更新开始")
        store.append(source: .crypto, level: .info, message: "资产更新完成")
        store.append(source: .crypto, level: .error, message: "资产更新出现错误")
        store.append(source: .crypto, level: .info, message: "资产同步完成")
        store.append(source: .hako, level: .info, message: "应用进入前台")
        store.flush()
        let restoredEntries = HakoLogStore(fileURL: file).snapshot().entries
        precondition(!restoredEntries.contains { $0.message == "应用进入前台" })
        let restoredCrypto = restoredEntries.filter { $0.source == .crypto }
        precondition(restoredCrypto.map(\.message) == ["资产同步完成", "资产更新出现错误"],
                     "hide only the two retired asset update events when restoring logs")
        let fullDetail = String(repeating: "HTTP diagnostic 正文\n", count: 700_000) + "RESPONSE-END"
        store.append(source: .headplane, level: .error, message: "HTTP failure", detail: fullDetail, fullDetail: true)
        store.flush()
        precondition(HakoLogStore(fileURL: file).snapshot().entries.first?.detail == fullDetail,
                     "Complete HTTP details must survive persistence even beyond the old 8 MB file limit")
        precondition(!HakoLog.safeURL("not a URL secret").contains("secret"))

        // Concurrent producers are serialized; retention and clear survive a restart.
        DispatchQueue.concurrentPerform(iterations: 1_100) { index in
            store.append(source: .hako, level: .info, message: "event \(index)", detail: String(repeating: "中", count: 5_000))
        }
        store.flush()
        let bounded = store.snapshot().entries
        precondition(bounded.count == HakoLogStore.capacity && Set(bounded.map(\.id)).count == bounded.count)
        precondition(bounded.allSatisfy { $0.detail.utf8.count <= 4_100 })
        precondition(HakoLogStore(fileURL: file).snapshot().entries.count == HakoLogStore.capacity)
        store.clear()
        precondition(store.snapshot().entries.isEmpty && HakoLogStore(fileURL: file).snapshot().entries.isEmpty)

        try Data("broken JSON".utf8).write(to: file)
        let damaged = HakoLogStore(fileURL: file)
        precondition(damaged.snapshot().issue != nil)
        damaged.append(source: .usage, level: .info, message: "recovered")
        damaged.flush()
        precondition(damaged.snapshot().issue == nil)
        precondition(HakoLogStore(fileURL: file).snapshot().entries.first?.message == "recovered")
        let blocked = HakoLogStore(fileURL: file.appendingPathComponent("events.json"))
        blocked.append(source: .hako, level: .error, message: "still available in memory")
        blocked.flush()
        precondition(blocked.snapshot().issue != nil && blocked.snapshot().entries.count == 1)
        print("Hako log URL redaction, credentials, persistence, retention, concurrency and clear checks passed")
    }

    private static func checkHangDiagnostics(at file: URL) async throws {
        let store = HakoLogStore(fileURL: file)
        store.append(source: .hako, level: .warning, message: HakoHangLog.message, detail: "持续时间：3 秒\nstack-one", fullDetail: true)
        store.append(source: .hako, level: .info, message: "ordinary-hako-event")
        store.append(source: .codeWorkshop, level: .warning, message: HakoHangLog.message, detail: "ordinary-workshop-event")
        store.append(source: .hako, level: .warning, message: HakoHangLog.message, detail: "持续时间：5 秒\nstack-two", fullDetail: true)
        let snapshot = await store.snapshotAsync()
        let reports = snapshot.entries.filter(HakoHangLog.includes)
        precondition(reports.count == 2 && reports[0].detail.contains("stack-two"))
        let exported = HakoLogExport.text(title: "卡顿诊断", entries: reports, version: "0.9.28")
        precondition(exported.contains("stack-one") && exported.contains("stack-two"))
        precondition(!exported.contains("ordinary-hako-event") && !exported.contains("ordinary-workshop-event"),
                     "Hang export leaked unrelated logs")
        await store.clearHangDiagnostics()
        let remaining = await store.snapshotAsync()
        precondition(remaining.entries.count == 2 && remaining.entries.allSatisfy { !HakoHangLog.includes($0) },
                     "Clearing hang diagnostics removed unrelated logs")
        let restored = await HakoLogStore(fileURL: file).snapshotAsync()
        precondition(restored.entries.map(\.id) == remaining.entries.map(\.id), "Hang clearing was not durable")
    }

    private static func checkHTTPLogs() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPLogMockProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://example.test/http-log?token=private-query")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("private-dpop", forHTTPHeaderField: "DPoP")
        request.httpBody = Data(#"{"label":"visible-request","clientSecret":"private-client"}"#.utf8)
        let (_, response) = try await HTTPTransport.data(for: request, using: session)
        precondition((response as? HTTPURLResponse)?.statusCode == 201)
        let entry = HakoLogStore.shared.snapshot().entries.first!
        precondition(entry.source == .hako && entry.message == "HTTP POST · 201")
        for expected in ["https://example.test/http-log", "请求头", "响应头", "visible-request", "visible-result", "http-log-regression"] {
            precondition(entry.detail.contains(expected))
        }
        for secret in ["private-query", "private-client", "private-dpop", "private-refresh", "private-cookie"] {
            precondition(!entry.text.contains(secret))
        }
        _ = try await HTTPTransport.data(for: request, using: session, logBody: false, logErrorBody: true)
        let success = HakoLogStore.shared.snapshot().entries.first!
        precondition(!success.detail.contains("visible-result") && !success.detail.contains("visible-request"),
                     "Credential success payloads must remain excluded")
        request.url = URL(string: "https://example.test/restricted?token=private-query")!
        let (failureBody, failureResponse) = try await HTTPTransport.data(for: request, using: session,
            secrets: ["private-client"], logBody: false, logErrorBody: true)
        precondition((failureResponse as? HTTPURLResponse)?.statusCode == 451 && !failureBody.isEmpty)
        let failure = HakoLogStore.shared.snapshot().entries.first!
        precondition(failure.detail.contains("visible-result") && !failure.detail.contains("visible-request"),
                     "Error response bodies must be logged even when request bodies are excluded")
        for secret in ["private-query", "private-client", "private-dpop", "private-refresh", "private-cookie"] {
            precondition(!failure.text.contains(secret), "Error bodies must still redact credentials")
        }
        var redactor = HTTPLogRedactor(request: request, secrets: [])
        let mixed = Data(#"{"tokens":[{"symbol":"TRX","balance":"123.45","access_token":"private-asset-token"}],"login":{"tokens":["private-token-list"]}}"#.utf8)
        let redacted = redactor.response(response as! HTTPURLResponse, data: mixed)
        precondition(redacted.contains("TRX") && redacted.contains("123.45"))
        precondition(!redacted.contains("private-asset-token") && !redacted.contains("private-token-list"))
        let large = Data(repeating: 65, count: HTTPLogRedactor.bodyLimit + 1)
        precondition(redactor.response(response as! HTTPURLResponse, data: large).contains("正文已省略"))
        do {
            _ = try await HTTPTransport.data(for: URLRequest(url: URL(string: "https://example.test/offline")!), using: session)
            preconditionFailure("Expected transport error")
        } catch let error as URLError { precondition(error.code == .notConnectedToInternet) }
        precondition(HakoLogStore.shared.snapshot().entries.first?.message == "HTTP GET · 无响应")
    }
}
