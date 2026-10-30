import Foundation

private final class ECSMockURLProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (Int, [String: Any]))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: body))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

@MainActor private final class ECSMockRenderer: ECSTerminalRendering {
    var output = Data()
    var resets = 0
    var focuses = 0
    var blurs = 0
    var keys: [String] = []
    func reset() { resets += 1; output.removeAll() }
    func feed(_ bytes: Data) { output.append(bytes) }
    func focus() { focuses += 1 }
    func blur() { blurs += 1 }
    func key(_ key: String) { keys.append(key) }
}

@MainActor private func checkTerminalDisplay(prompt: Data) {
    let display = ECSTerminalDisplay(limit: 16)
    display.append(prompt) // Output can arrive before UIKit is attached.
    let firstRenderer = ECSMockRenderer()
    display.attach(firstRenderer)
    precondition(firstRenderer.output == prompt && firstRenderer.resets == 1)
    display.append(Data("hello\r\n".utf8))
    let replacementRenderer = ECSMockRenderer()
    display.attach(replacementRenderer)
    display.detach(firstRenderer) // A retiring view must not detach its replacement.
    display.focus(); display.key("Tab")
    precondition(replacementRenderer.output == firstRenderer.output && replacementRenderer.focuses == 1)
    precondition(replacementRenderer.keys == ["Tab"] && firstRenderer.keys.isEmpty)
    display.beginSession()
    precondition(display.bytes.isEmpty && replacementRenderer.output.isEmpty && replacementRenderer.resets == 2)
    display.append(Data(repeating: 65, count: 48))
    precondition(display.bytes.count == 16 && replacementRenderer.output.count == 48)
    let lateRenderer = ECSMockRenderer()
    display.attach(lateRenderer)
    precondition(lateRenderer.output.count == 16 && lateRenderer.keys.isEmpty)
}

@main struct ECSTests {
    static func main() async throws {
        func fails(_ action: () throws -> Void) {
            do { try action(); fatalError("Expected failure") } catch { }
        }
        var connection = ECSConnection(name: "测试", instanceID: "i-test", accessKeyID: "testid", accessKeySecret: "testsecret")
        _ = try connection.validated()
        for bad in ["root; id", "../root", "root\nother", "-root"] {
            var changed = connection; changed.username = bad; fails { _ = try changed.validated() }
        }
        var invalid = connection; invalid.region = "cn-hangzhou.example.com"; fails { _ = try invalid.validated() }
        invalid = connection; invalid.instanceID = "i-test\"],\"other\""; fails { _ = try invalid.validated() }
        let parameters = ["Timestamp": "2016-02-23T12:46:24Z", "Format": "XML", "AccessKeyId": "testid", "Action": "DescribeRegions",
            "SignatureMethod": "HMAC-SHA1", "SignatureNonce": "3ee8c1b8-83d3-44af-a94f-4e0ad82fd6cf", "Version": "2014-05-26", "SignatureVersion": "1.0"]
        precondition(ECSRPC.signature(parameters, secret: "testsecret", method: "GET") == "OLeaidS1JvxuMvnyHOwuJ+uX5qY=")
        precondition(ECSRPC.encode(" +/*~汉") == "%20%2B%2F%2A~%E6%B1%89")
        connection.securityToken = "token+/="
        let request = ECSRPC.request(connection: connection, action: "StartTerminalSession", parameters: ["InstanceId.1": "i-test"], now: Date(timeIntervalSince1970: 0), nonce: "fixed")
        precondition(request.httpMethod == "POST" && request.url?.query == nil)
        let body = String(decoding: request.httpBody!, as: UTF8.self)
        precondition(body.contains("SecurityToken=token%2B%2F%3D") && !body.contains("testsecret"))

        let frame = ECSAXTFrame(type: 1, channel: "通道", instance: "i-test", timestamp: 123, input: 7, output: 9, payload: Data([0, 0xff, 0xe4, 0xb8, 0xad]))
        let encoded = try frame.encode()
        let decoded = try ECSAXTFrame.decode(encoded)
        precondition(decoded == frame)
        for count in 0..<encoded.count { fails { _ = try ECSAXTFrame.decode(Data(encoded.prefix(count))) } }
        fails { _ = try ECSAXTFrame.decode(encoded + Data([0])) }
        fails { _ = try ECSAXTFrame(type: 0, channel: String(repeating: "x", count: 256)).encode() }
        fails { _ = try ECSAXTFrame(type: 0, payload: Data(repeating: 0, count: 65536)).encode() }
        precondition(ECSAXTFlow.size(columns: 80, rows: 24) == Data([24, 0, 80, 0]))
        var flow = ECSAXTFlow()
        let ready = try flow.receive(ECSAXTFrame(type: 5, channel: "channel", payload: Data([3])))
        precondition(ready.ready)
        let input = try flow.message(type: 0, payload: Data("echo test\r".utf8))
        let retry = try flow.receive(ECSAXTFrame(type: 6, channel: "channel", input: 1))
        precondition(retry.replies == [input])
        let gap = try flow.receive(ECSAXTFrame(type: 1, channel: "channel", input: 1, output: 2, payload: Data("second".utf8)))
        precondition(gap.bytes.isEmpty && gap.replies.first?.type == 6)
        let first = try flow.receive(ECSAXTFrame(type: 1, channel: "channel", input: 1, output: 1, payload: Data([0xe4])))
        precondition(first.bytes == Data([0xe4]))
        let duplicate = try flow.receive(ECSAXTFrame(type: 1, channel: "channel", input: 1, output: 1, payload: Data([0xe4])))
        precondition(duplicate.bytes.isEmpty)
        let rest = try flow.receive(ECSAXTFrame(type: 1, channel: "channel", input: 1, output: 2, payload: Data([0xb8, 0xad])))
        precondition(String(data: first.bytes + rest.bytes, encoding: .utf8) == "中")
        let acknowledged = try flow.receive(ECSAXTFrame(type: 6, channel: "channel", input: 1))
        precondition(acknowledged.replies.isEmpty)
        fails { _ = try flow.receive(ECSAXTFrame(type: 1, channel: "other", output: 3)) }

        // Some agent streams start at output sequence zero. It is a first packet,
        // not a duplicate; later zero packets must still be suppressed.
        var zeroFlow = ECSAXTFlow()
        _ = try zeroFlow.receive(ECSAXTFrame(type: 5, channel: "zero", payload: Data([3])))
        let prompt = try zeroFlow.receive(ECSAXTFrame(type: 1, channel: "zero", output: 0, payload: Data("root# ".utf8)))
        precondition(prompt.firstOutput && prompt.ready && String(decoding: prompt.bytes, as: UTF8.self) == "root# ")
        let repeatedPrompt = try zeroFlow.receive(ECSAXTFrame(type: 1, channel: "zero", output: 0, payload: prompt.bytes))
        precondition(repeatedPrompt.bytes.isEmpty && !repeatedPrompt.firstOutput)
        let typed = try zeroFlow.message(type: 0, payload: Data("pwd\r".utf8))
        precondition(typed.input == 1 && typed.output == 0)
        let echo = try zeroFlow.receive(ECSAXTFrame(type: 1, channel: "zero", input: 1, output: 1, payload: Data("pwd\r\n/root\r\n".utf8)))
        precondition(!echo.bytes.isEmpty && !echo.firstOutput && echo.replies.isEmpty)
        var outputOnly = ECSAXTFlow()
        let immediate = try outputOnly.receive(ECSAXTFrame(type: 1, channel: "direct", output: 0, payload: prompt.bytes))
        precondition(immediate.ready && immediate.firstOutput && immediate.bytes == prompt.bytes)

        await checkTerminalDisplay(prompt: prompt.bytes)

        let snapshot = try ECSSnapshot.decode(Data(#"{"version":1,"time":100,"interfaces":[],"processes":[],"truncated":false}"#.utf8))
        precondition(snapshot.memoryAvailable == nil && snapshot.sockets == nil)
        fails { _ = try ECSSnapshot.decode(Data(#"{"version":2,"time":100}"#.utf8)) }
        connection.region = "cn-chengdu"
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ECSMockURLProtocol.self]
        let client = try ECSClient(connection: connection, session: URLSession(configuration: config))
        ECSMockURLProtocol.handler = { _ in
            (200, ["MonitorData": ["InstanceMonitorData": [["TimeStamp": "2026-10-30T00:00:00Z", "CPU": 25,
                "IntranetRX": 480, "IntranetTX": 960, "BPSRead": 1234]]]])
        }
        let points = try await client.monitor()
        precondition(points.count == 1 && points[0].receiveBytesPerSecond == 1000 && points[0].sendBytesPerSecond == 2000)
        precondition(points[0].writeBytesPerSecond == nil)
        ECSMockURLProtocol.handler = { _ in (403, ["Code": "Forbidden", "Message": "never-display-testsecret"]) }
        do { _ = try await client.instance(); fatalError("Expected provider error") }
        catch { precondition(!error.localizedDescription.contains("testsecret")) }
        ECSMockURLProtocol.handler = { _ in (404, ["Code": "InvalidSessionId.NotFound"]) }
        try await client.endTerminal("ended-session")
        var cleanedRejectedSession = false
        var returnedAddress = "https://cn-chengdu-axt.aliyuncs.com:443/session?sessionId=s-private-test&token=secret-test-token"
        ECSMockURLProtocol.handler = { request in
            var body = request.httpBody ?? Data()
            if body.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4_096)
                while true {
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    if count <= 0 { break }
                    body.append(contentsOf: bytes.prefix(count))
                }
            }
            if String(decoding: body, as: UTF8.self).contains("Action=EndTerminalSession") {
                cleanedRejectedSession = true
                return (200, [:])
            }
            return (200, ["SessionId": "s-private-test", "SecurityToken": "secret-test-token",
                "WebSocketUrl": returnedAddress])
        }
        do { _ = try await client.startTerminal(); fatalError("Expected rejected non-WebSocket scheme") }
        catch { precondition(error is ECSFailure) }
        precondition(cleanedRejectedSession)
        let addressLog = HakoLogStore.shared.snapshot().entries.first { $0.message == "阿里云返回终端连接地址" }
        precondition(addressLog?.detail.contains("cn-chengdu-axt.aliyuncs.com:443/session") == true)
        precondition(addressLog?.detail.contains("s-private-test") == false && addressLog?.detail.contains("secret-test-token") == false)
        // The API controls host/port/path, including endpoints not derived from
        // RegionId. Preserve its full URL and signed query rather than rebuilding it.
        for endpoint in [
            "wss://cn-chengdu-axt.aliyuncs.com/session",
            "wss://cn-chengdu.axt.aliyuncs.com/session",
            "wss://cn-chengdu-axt.aliyuncs.com:443/session",
            "wss://axt.cn-chengdu.aliyuncs.com:8443/terminal/session",
            "wss://terminal.example.com/session"
        ] {
            returnedAddress = endpoint + "?sessionId=s-private-test&token=secret-test-token%2B%2F%3D&version=1"
            cleanedRejectedSession = false
            let lease = try await client.startTerminal()
            precondition(lease.id == "s-private-test" && lease.url.absoluteString == returnedAddress)
            precondition(!cleanedRejectedSession)
            try await client.endTerminal(lease.id)
        }
        for rejected in [
            "/session?token=secret-test-token",
            "wss:///session",
            "wss://cn-chengdu-axt.aliyuncs.com:70000/session",
            "wss://user:password@cn-chengdu-axt.aliyuncs.com/session",
            "ws://cn-chengdu-axt.aliyuncs.com/session",
            "https://cn-chengdu-axt.aliyuncs.com/session"
        ] {
            returnedAddress = rejected; cleanedRejectedSession = false
            do { _ = try await client.startTerminal(); fatalError("Expected rejected endpoint") }
            catch { precondition(error is ECSFailure) }
            precondition(cleanedRejectedSession)
        }
        print("ECS signing, response mapping, snapshots and terminal protocol checks passed")
    }
}
