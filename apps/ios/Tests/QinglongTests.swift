import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class QinglongMockProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var handler: ((URLRequest) throws -> (Int, String))?
    static func respond(_ block: @escaping (URLRequest) throws -> (Int, String)) {
        lock.lock(); defer { lock.unlock() }; handler = block
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            Self.lock.lock()
            let result: Result<(Int, String), Error>
            do { result = .success(try Self.handler!(request)) } catch { result = .failure(error) }
            Self.lock.unlock()
            let (status, text) = try result.get()
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    static func body(_ request: URLRequest) -> Data? {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}

@main struct QinglongTests {
    static func main() async throws {
        let decoder = JSONDecoder()
        func json(_ value: String) throws -> QinglongJSON { try decoder.decode(QinglongJSON.self, from: Data(value.utf8)) }
        func reject(_ connection: QinglongConnection) {
            do { _ = try connection.normalized(); fatalError("Invalid connection accepted") } catch is QinglongFailure {} catch { fatalError("Unexpected error") }
        }
        var connection = QinglongConnection(name: "测试面板", address: "https://panel.example.com/panel/open/", clientID: "demo+id", clientSecret: "test?secret&=", headers: [QinglongHeader(name: "X-Service", value: "qinglong")])
        connection = try connection.normalized()
        precondition(connection.address == "https://panel.example.com/panel")
        let request = try connection.request(["envs"])
        precondition(request.url?.absoluteString == "https://panel.example.com/panel/open/envs")
        precondition(request.value(forHTTPHeaderField: "X-Service") == "qinglong")
        for name in ["Authorization", "host", "Content-Type", "Accept", "bad header", "X-Test\n"] {
            var invalid = connection; invalid.headers = [QinglongHeader(name: name == "X-Test\n" ? "X\nTest" : name, value: "value")]; reject(invalid)
        }
        var invalid = connection; invalid.headers = [QinglongHeader(name: "X-Test", value: "injected\r\nValue")]; reject(invalid)
        invalid = connection; invalid.headers += [QinglongHeader(name: "x-service", value: "duplicate")]; reject(invalid)
        invalid = connection; invalid.headers = [QinglongHeader()]; let emptyHeaders = try invalid.normalized(); precondition(emptyHeaders.headers.isEmpty)
        for address in ["http://panel.local", "https://u:p@panel.local", "https://panel.local?secret=a", "https://panel.local/#login", "https://panel.local/a/../b"] {
            invalid = connection; invalid.address = address; reject(invalid)
        }
        for (name, directory) in [("../file", ""), ("file.py", "../scripts"), ("file.py", "/absolute"), ("file\n.py", "")] {
            do { try QinglongParsing.file(name, directory: directory); fatalError("Unsafe file accepted") } catch is QinglongFailure {}
        }
        let tree = try json(#"[{"title":"repo","type":"directory","children":[{"title":"demo.py","parent":"repo","key":"repo/demo.py","type":"file"}]}]"#)
        let files = try QinglongParsing.items(tree, resource: .scripts)
        precondition(files.count == 1 && files[0].filename == "demo.py" && files[0].directory == "repo")
        let sub = QinglongItem(resource: .subscriptions, raw: try json(#"{"id":7,"type":"private-repo","url":"https://repo.example.com","alias":"repo","schedule_type":"interval","interval_schedule":{"type":"hours","value":2},"is_disabled":1,"autoAddCron":1,"pull_option":{"username":"u","password":"p"},"status":1}"#))
        precondition(sub.disabled)
        let edited = sub.editPayload(["name":"renamed"])
        precondition(edited["interval_schedule"]["value"].int == 2 && edited["pull_option"]["password"].text == "p" && edited["autoAddCron"] == .bool(true) && edited["status"] == .null)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [QinglongMockProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = try QinglongClient(connection: connection, session: session)
        var tokenRequests = 0, listRequests = 0
        QinglongMockProtocol.respond { request in
            precondition(request.value(forHTTPHeaderField: "X-Service") == "qinglong")
            if request.url!.path.hasSuffix("auth/token") {
                tokenRequests += 1
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                precondition(query.first { $0.name == "client_id" }?.value == connection.clientID)
                precondition(query.first { $0.name == "client_secret" }?.value == connection.clientSecret)
                return (200, #"{"code":200,"data":{"token":"test-access-token","expiration":9999999999}}"#)
            }
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-access-token")
            listRequests += 1
            let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "page" }!.value!
            return (200, "{\"code\":200,\"data\":{\"data\":[{\"id\":\(page),\"name\":\"task-\(page)\",\"status\":1}],\"total\":2}}")
        }
        let list = try await client.list(.tasks)
        precondition(list.count == 2 && listRequests == 2 && tokenRequests == 1)
        _ = try await client.list(.tasks)
        precondition(tokenRequests == 1, "Token must be cached")
        var writes = 0
        QinglongMockProtocol.respond { request in
            writes += 1
            precondition(request.httpMethod == "PUT")
            throw URLError(.timedOut)
        }
        do { try await client.action("run", item: list[0]); fatalError("Timeout accepted") }
        catch let failure as QinglongFailure { precondition(failure.outcomeUnknown) }
        precondition(writes == 1, "Never retry an uncertain mutation")
        QinglongMockProtocol.respond { _ in (200, #"{"code":403,"message":"secret must not be echoed"}"#) }
        do { _ = try await client.list(.envs); fatalError("Business error accepted") }
        catch let failure as QinglongFailure { precondition(failure.status == 403 && !failure.message.contains("secret")) }
        QinglongMockProtocol.respond { _ in (500, "not json") }
        do { try await client.action("run", item: list[0]); fatalError("Server error accepted") }
        catch let failure as QinglongFailure { precondition(failure.outcomeUnknown) }
        QinglongMockProtocol.respond { _ in (200, #"{"code":401}"#) }
        do { _ = try await client.list(.envs); fatalError("Expired token accepted") } catch is QinglongFailure {}
        tokenRequests = 0
        QinglongMockProtocol.respond { request in
            if request.url!.path.hasSuffix("auth/token") { tokenRequests += 1; return (200, #"{"code":200,"data":{"token":"new","expiration":9999999999}}"#) }
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer new")
            return (200, #"{"code":200,"data":[]}"#)
        }
        _ = try await client.list(.envs)
        precondition(tokenRequests == 1, "Next explicit request obtains a new token")
        var bodyChecked = false
        QinglongMockProtocol.respond { request in
            precondition(request.httpMethod == "PUT" && request.url!.path.hasSuffix("scripts"))
            if let body = QinglongMockProtocol.body(request) { let payload = try json(String(decoding: body, as: UTF8.self)); precondition(payload["filename"].text == "demo.py" && payload["content"].text == ""); bodyChecked = true }
            return (200, #"{"code":200}"#)
        }
        try await client.saveFile(files[0], content: "")
        precondition(bodyChecked, "Empty file content must be sent explicitly")
        let failure = QinglongOutcome(raw: try json(#"{"status":1,"exit_code":1,"started_at":1793670000}"#))
        let success = QinglongOutcome(raw: try json(#"{"status":1,"exit_code":0}"#))
        let unknown = QinglongOutcome(raw: try json(#"{"status":1}"#))
        precondition(failure.failed && !failure.succeeded && success.succeeded && !success.failed)
        precondition(!unknown.succeeded && !unknown.failed, "Missing exit code must not imply success")
        QinglongMockProtocol.respond { request in
            precondition(request.url!.path.hasSuffix("crons/1/instances"))
            return (200, #"{"code":200,"data":[{"status":1,"exit_code":0,"started_at":100},{"status":3,"started_at":200}]}"#)
        }
        let outcome = try await client.latestOutcome(list[0])
        precondition(outcome?.failed == true, "Use the newest real instance, independent of response ordering")
        var environmentRequests = [String]()
        QinglongMockProtocol.respond { request in
            let path = request.url!.path
            environmentRequests.append(request.httpMethod! + " " + path)
            if path.hasSuffix("envs/disable") {
                let ids = try json(String(decoding: QinglongMockProtocol.body(request)!, as: UTF8.self))
                precondition(ids == .array([.number(42)]))
                return (200, #"{"code":200}"#)
            }
            precondition(request.httpMethod == "POST")
            let body = try json(String(decoding: QinglongMockProtocol.body(request)!, as: UTF8.self))
            precondition(body.array?.first?["name"].text == "TEST_ENV" && body.array?.first?["status"] == .null)
            return (200, #"{"code":200,"data":[{"id":42,"name":"TEST_ENV","value":"demo","status":0}]}"#)
        }
        let fields = ["name": "TEST_ENV", "value": "demo", "remarks": "test"]
        let disabledEnvironment = try await client.saveEnvironment(nil, fields: fields, enabled: false)
        precondition(disabledEnvironment.item?.numberID == 42 && disabledEnvironment.stateError == nil && environmentRequests.count == 2)
        environmentRequests = []
        let enabledEnvironment = try await client.saveEnvironment(nil, fields: fields, enabled: true)
        precondition(enabledEnvironment.stateError == nil && environmentRequests.count == 1, "Default enabled creation requires no extra mutation")
        QinglongMockProtocol.respond { request in
            if request.url!.path.hasSuffix("envs/enable") { return (403, #"{"code":403}"#) }
            precondition(request.httpMethod == "PUT")
            return (200, #"{"code":200,"data":{"id":42,"name":"TEST_ENV","value":"demo","status":1}}"#)
        }
        let oldEnvironment = QinglongItem(resource: .envs, raw: try json(#"{"id":42,"status":1}"#))
        let partial = try await client.saveEnvironment(oldEnvironment, fields: fields, enabled: true)
        precondition(partial.item?.numberID == 42 && partial.stateError != nil, "Preserve the saved ID when only the state operation fails")
        QinglongMockProtocol.respond { _ in (200, #"{"code":200,"data":[]}"#) }
        let missingID = try await client.saveEnvironment(nil, fields: fields, enabled: false)
        precondition(missingID.item == nil && missingID.stateError != nil, "Never invent an ID or repeat creation after an incomplete save response")
        print("Qinglong tests passed, including environment create/state changes and partial-save recovery.")
    }
}
