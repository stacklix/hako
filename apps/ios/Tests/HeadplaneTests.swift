import Foundation

private func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: "Tests/Fixtures/Headplane/\(name).data"))
}
private func payload(_ name: String, _ resource: HeadplaneResource) throws -> HeadplaneJSON {
    try HeadplaneStream.payload(HeadplaneStream.decode(fixture(name)), resource: resource)
}
private func rejects(_ body: () throws -> Void) {
    do { try body(); preconditionFailure("Expected rejection") } catch {}
}

private final class WireProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))!
    static func respond(_ body: @escaping (URLRequest) throws -> (Int, [String: String], Data)) {
        lock.lock(); defer { lock.unlock() }; handler = body
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let response = Result { try Self.handler(request) }
        Self.lock.unlock()
        do {
            let (code, headers, data) = try response.get()
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    static func body(_ request: URLRequest) -> String {
        if let body = request.httpBody { return String(decoding: body, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return String(decoding: data, as: UTF8.self)
    }
}

private actor ControlledAccess: HeadplaneAccess {
    let machineData: HeadplaneJSON
    var policyData: HeadplaneJSON
    var submits = 0
    var failure = false
    var readFailure = false
    var pauseNext = false
    var incompleteKeys = false
    var continuation: CheckedContinuation<HeadplaneJSON, Error>?
    init() throws { machineData = try payload("machines", .machines); policyData = try payload("policy", .policy) }
    func read(_ resource: HeadplaneResource) async throws -> HeadplaneJSON {
        if pauseNext { pauseNext = false; return try await withCheckedThrowingContinuation { continuation = $0 } }
        if readFailure { throw HeadplaneFailure(message: "Offline") }
        if resource == .keys {
            var keys = try payload("keys", .keys).object
            keys["missing"] = .array(incompleteKeys ? [.object(["user": .string("unavailable")])] : [])
            return .object(keys)
        }
        return resource == .policy ? policyData : machineData
    }
    func submit(_ resource: HeadplaneResource, fields: [String: String]) async throws -> HeadplaneJSON {
        submits += 1
        if failure { throw HeadplaneFailure(message: "Timeout", outcomeUnknown: true) }
        return .object(["success": .bool(true)])
    }
    func configure(failure: Bool = false, readFailure: Bool = false, pause: Bool = false) {
        self.failure = failure; self.readFailure = readFailure; pauseNext = pause
    }
    func waiting() -> Bool { continuation != nil }
    func incomplete(_ value: Bool) { incompleteKeys = value }
    func release() { continuation?.resume(returning: machineData); continuation = nil }
}

private final class MemorySecrets: SecretStorage {
    var value: Data?
    var fail = false
    func read(account: String) throws -> Data? { value }
    func save(_ data: Data, account: String, accessibility: SecretAccessibility) throws {
        precondition(account == "connection" && accessibility == .whenUnlocked)
        if fail { throw HeadplaneFailure(message: "Locked") }; value = data
    }
    func delete(account: String) throws { value = nil }
    func accounts() throws -> [String] { value == nil ? [] : ["connection"] }
}

@main struct HeadplaneTests {
    static let connection = HeadplaneConnection(address: "https://headplane.example.test/admin/", apiKey: "test+only&key=42")

    static func decoding() throws {
        let data = try payload("machines", .machines), machines = try HeadplaneMachines(data)
        precondition(machines.nodes.count == 2 && machines.writable && machines.preAuth)
        precondition(machines.nodes[0].name == "home-router" && machines.nodes[0].online && !machines.nodes[0].expired)
        precondition(machines.nodes[0].subnetRoutes == ["192.168.1.0/24"])
        precondition(machines.nodes[0].exitRoutes.count == 2 && !machines.nodes[0].exitApproved)
        precondition(machines.nodes[1].os.isEmpty && machines.nodes[1].status == "离线")
        let oidcUser = try HeadplaneUser(.object(["id": .string("5"), "name": .string(""), "displayName": .string("Alice")]))
        precondition(oidcUser.name == "Alice", "OIDC-created Headscale users can have an empty username")
        let policy = try HeadplanePolicy(payload("policy", .policy))
        precondition(policy.writable && policy.text.contains("// Keep this comment"))
        precondition(policy.summary?["acls"].array?.count == 1)
        let specials = try HeadplaneStream.decode(fixture("specials"))
        precondition(specials["date"].text == "2026-11-03T00:00:00Z" && specials["nil"] == .null && specials["absent"] == .null)
        precondition(specials["set"].strings == ["tag:router"] && specials["large"].text == "9007199254740993")
        do { _ = try payload("denied", .policy); preconditionFailure() }
        catch let e as HeadplaneFailure { precondition(e.status == 403 && e.message == "Permission denied") }
        for malformed in ["[]", "<html>Sign in</html>", "[{\"_1\":0},\"self\"]", "[{\"_9999\":0}]", "[[\"UnexpectedTag\",1],2]"] {
            rejects { _ = try HeadplaneStream.decode(Data(malformed.utf8)) }
        }
        rejects { _ = try HeadplaneMachines(.object(["nodes": .array([])])) }
        var duplicate = data.object; duplicate["populatedNodes"] = .array([data["populatedNodes"].array![0], data["populatedNodes"].array![0]])
        rejects { _ = try HeadplaneMachines(.object(duplicate)) }
        let keyData = try payload("keys", .keys)["keys"].array![0]
        let key = try HeadplaneKey(keyData["preAuthKeys"].array![0], user: keyData["user"])
        precondition(key.active && key.userID == "1")
        print("PASS official encoder fixtures, policy comments, routes, invalid/cyclic data")
    }

    static func configuration() throws {
        let normalized = try connection.normalized()
        precondition(normalized.address == "https://headplane.example.test/admin")
        let request = try normalized.request(.machines)
        precondition(request.url?.path == "/admin/machines.data")
        precondition(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "routes/machines/overview")
        for address in ["http://example.test/admin", "https://name:secret@example.test/admin", "https://example.test/admin?key=x", "https://example.test/admin#part", "https://example.test/a/../admin", "file:///admin"] {
            rejects { _ = try HeadplaneConnection(address: address, apiKey: "test-key").normalized() }
        }
        let local = try HeadplaneConnection(address: "http://127.0.0.1:8080", apiKey: "test-key", allowHTTP: true).normalized()
        precondition(local.address == "http://127.0.0.1:8080/admin")
        precondition(String(decoding: HeadplaneClient.form(["api_key": connection.apiKey]), as: UTF8.self) == "api_key=test%2Bonly%26key%3D42")
        let storage = MemorySecrets()
        try HeadplaneCredentials.save(connection, storage: storage)
        let loaded = try HeadplaneCredentials.load(storage: storage)
        precondition(loaded == normalized)
        let saved = storage.value; storage.fail = true
        rejects { try HeadplaneCredentials.save(HeadplaneConnection(address: "https://other.test", apiKey: "different"), storage: storage) }
        precondition(storage.value == saved)
        storage.value = Data("corrupt".utf8)
        rejects { _ = try HeadplaneCredentials.load(storage: storage) }
        precondition(storage.value == Data("corrupt".utf8))
        print("PASS URL, form encoding and isolated credential storage")
    }

    static func agentStatus() throws {
        let healthy = try HeadplaneAgentStatus(payload("agent", .agent))
        precondition(healthy.nodeCount == 3 && healthy.nodeCountText == "3" && healthy.healthy)
        let failed = try HeadplaneAgentStatus(payload("agentError", .agent))
        precondition(failed.status == "同步异常" && !failed.healthy && failed.nodeCountText == "3")
        precondition(failed.error == "Headscale is unavailable" && !failed.syncedAt.isEmpty)
        let pending = try HeadplaneAgentStatus(payload("agentPending", .agent))
        precondition(pending.status == "等待授权" && pending.needsApproval && pending.nodeCountText == "0")
        let disabled = try HeadplaneAgentStatus(payload("agentDisabled", .agent))
        precondition(!disabled.enabled && disabled.status == "Agent 未启用" && disabled.reason == "Agent is not configured")
        let missing = try HeadplaneAgentStatus(.object(["enabled": .bool(true), "machineCount": .number(42)]))
        precondition(missing.nodeCountText == "未提供" && missing.status == "等待同步", "Missing v0.8.2 nodeCount must not be invented or read from another field")
        rejects { _ = try HeadplaneAgentStatus(.object([:])) }
        print("PASS Agent v0.8.2 node count, zero/missing values, synchronization errors and approval states")
    }

    static func networking() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WireProtocol.self]; config.httpCookieStorage = nil; config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var logins = 0, gets = 0, posts = 0
        let machines = try fixture("machines"), action = try fixture("action"), login = try fixture("login"), created = try fixture("created")
        WireProtocol.respond { request in
            if request.url!.path == "/admin/login" {
                logins += 1
                precondition(request.httpMethod == "POST" && WireProtocol.body(request) == "api_key=test%2Bonly%26key%3D42")
                precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
                return (302, ["Location": "/admin/machines", "Set-Cookie": "headplane=session; Path=/admin; Secure; HttpOnly"], Data())
            }
            precondition(request.value(forHTTPHeaderField: "Cookie") == "headplane=session")
            precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
            if request.httpMethod == "GET" {
                gets += 1
                return (gets == 1 ? 202 : 200, [:], gets == 1 ? login : machines)
            }
            posts += 1
            precondition(request.url!.query == "index=" && request.value(forHTTPHeaderField: "Origin") == "https://headplane.example.test")
            precondition(WireProtocol.body(request).contains("action_id=rename"))
            return (200, [:], action)
        }
        let client = try HeadplaneClient(connection: connection, session: session)
        _ = try await client.read(.machines)
        precondition(logins == 2 && gets == 2, "Expired reads retry exactly once")
        _ = try await client.submit(.machines, fields: ["action_id": "rename", "node_id": "2", "name": "router"])
        precondition(posts == 1 && logins == 2)
        WireProtocol.respond { _ in posts += 1; throw URLError(.timedOut) }
        do { _ = try await client.submit(.machines, fields: ["action_id": "delete"]); preconditionFailure() }
        catch let e as HeadplaneFailure { precondition(e.outcomeUnknown) }
        precondition(posts == 2, "Unknown writes must never replay")
        WireProtocol.respond { _ in (200, [:], action) }
        do { _ = try await client.submit(.keys, fields: ["action_id": "add_preauthkey"]); preconditionFailure() }
        catch let e as HeadplaneFailure { precondition(e.outcomeUnknown, "Missing created key must not be success") }
        WireProtocol.respond { _ in (200, [:], created) }
        let key = try await client.submit(.keys, fields: ["action_id": "add_preauthkey"])
        precondition(key["key"].text == "test-only-new-key")
        let agentError = try fixture("agentError")
        WireProtocol.respond { _ in (200, [:], agentError) }
        let store = await HeadplaneStore(client: client)
        await store.refresh(.agent)
        let agent = await store.agent, loadError = await store.errors[.agent]
        precondition(agent?.nodeCountText == "3" && agent?.status == "同步异常" && loadError == nil,
                     "Agent synchronization errors are displayable status, not failed HTTP reads")
        WireProtocol.respond { _ in (503, [:], agentError) }
        do { _ = try await client.read(.agent); preconditionFailure() }
        catch let e as HeadplaneFailure { precondition(e.status == 503, "Real HTTP failures must remain errors") }
        WireProtocol.respond { _ in (302, ["Location": "https://attacker.example.test/machines", "Set-Cookie": "session=x; Path=/"], Data()) }
        let bad = try HeadplaneClient(connection: connection, session: session)
        do { _ = try await bad.submit(.machines, fields: ["action_id": "rename"]); preconditionFailure() }
        catch let e as HeadplaneFailure { precondition(e.status == 401) }
        print("PASS session login, cookie isolation, safe read retry, no write replay, cross-origin rejection")
    }

    @MainActor static func storeBehavior() async throws {
        let remote = try ControlledAccess(), store = HeadplaneStore(client: remote)
        await store.refresh(.machines)
        precondition(store.machines?.nodes.count == 2)
        do { _ = try await store.mutate(.machines, revision: UUID(), fields: [:]); preconditionFailure() } catch {}
        do { _ = try await store.mutate(.policy, revision: store.revision, fields: ["policy": "{}"], originalPolicy: "changed elsewhere"); preconditionFailure() } catch {}
        let blockedCount = await remote.submits
        precondition(blockedCount == 0, "Stale connection and policy conflict block writes")
        await remote.configure(failure: true, pause: true)
        let oldRead = Task { await store.refresh(.machines) }
        for _ in 0..<10_000 { if await remote.waiting() { break }; await Task.yield() }
        let waiting = await remote.waiting()
        precondition(waiting)
        do { _ = try await store.mutate(.machines, revision: store.revision, fields: [:]); preconditionFailure() } catch {}
        precondition(store.pending == .machines)
        await remote.release(); await oldRead.value
        precondition(store.pending == .machines, "A read begun before the failed write cannot confirm its result")
        do { _ = try await store.mutate(.machines, revision: store.revision, fields: [:]); preconditionFailure() } catch {}
        let pendingCount = await remote.submits
        precondition(pendingCount == 1)
        await remote.configure(); await store.refresh(.machines)
        precondition(store.pending == nil)
        await remote.configure(readFailure: true)
        _ = try await store.mutate(.machines, revision: store.revision, fields: [:])
        precondition(store.pending == .machines && store.machines?.nodes.count == 2, "Failed read-back retains cached state and blocks repeat writes")
        await remote.configure(); await store.refresh(.machines)
        precondition(store.pending == nil && store.errors[.machines] == nil)
        await remote.configure(failure: true)
        do { _ = try await store.mutate(.keys, revision: store.revision, fields: [:]); preconditionFailure() } catch {}
        await remote.configure(); await remote.incomplete(true); await store.refresh(.keys)
        precondition(store.pending == .keys && store.errors[.keys] != nil, "Partial key lists cannot confirm an uncertain create")
        await remote.incomplete(false); await store.refresh(.keys)
        precondition(store.pending == nil)
        print("PASS stale reads, conflict detection and uncertain-write recovery")
    }

    static func main() async throws {
        try decoding(); try configuration(); try agentStatus(); try await networking(); try await storeBehavior()
        print("Headplane tests passed")
    }
}
