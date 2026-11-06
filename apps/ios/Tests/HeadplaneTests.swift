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
    var details: [String: HeadplaneJSON] = [:]
    var detailFailure: HeadplaneFailure?
    init() throws { machineData = try payload("machines", .machines); policyData = try payload("policy", .policy) }
    func read(_ resource: HeadplaneResource) async throws -> HeadplaneJSON {
        if pauseNext { pauseNext = false; return try await withCheckedThrowingContinuation { continuation = $0 } }
        if readFailure { throw HeadplaneFailure(message: "Offline") }
        if case .machine(let id) = resource {
            if let detailFailure { throw detailFailure }
            return try details[id] ?? payload(id == "2" ? "machineDetail" : "machineNoAgent", resource)
        }
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
    func release(_ data: HeadplaneJSON? = nil) { continuation?.resume(returning: data ?? machineData); continuation = nil }
    func setDetail(_ data: HeadplaneJSON, id: String) { details[id] = data }
    func failDetail(_ status: Int?) { detailFailure = status.map { HeadplaneFailure(message: "Detail unavailable", status: $0) } }
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
        let legacy = Data(#"{"name":"Homelab","address":"https://headplane.example.test/admin","apiKey":"test-key","allowHTTP":false}"#.utf8)
        let legacyConnection = try JSONDecoder().decode(HeadplaneConnection.self, from: legacy)
        precondition(legacyConnection.infoSecret == nil)
        var diagnostic = connection
        diagnostic.infoSecret = " test-only-info-secret "
        let normalizedDiagnostic = try diagnostic.normalized()
        precondition(normalizedDiagnostic.infoSecret == "test-only-info-secret")
        storage.fail = false
        try HeadplaneCredentials.save(diagnostic, storage: storage)
        let reloadedDiagnostic = try HeadplaneCredentials.load(storage: storage)
        precondition(reloadedDiagnostic?.infoSecret == "test-only-info-secret")
        diagnostic.infoSecret = "bad\nheader"
        rejects { _ = try diagnostic.normalized() }
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

    static func machineDetails() throws {
        let data = try payload("machineDetail", .machine("2"))
        let detail = try HeadplaneMachineDetail(data, nodeID: "2")
        precondition(detail.node.id == "2" && detail.node.name == "detail-router" && detail.hostname == "router-os")
        precondition(detail.domain == "detail-router.tail.example.test" && detail.createdAt == "2026-01-01T00:00:00Z")
        precondition(detail.isAgent && detail.agent?.nodeCount == 0 && detail.agent?.syncedAt == "2026-11-04T00:00:00Z")
        precondition(detail.host?.system == "linux 6.12.0" && detail.host?.distribution == "debian 13")
        precondition(detail.host?.version == "1.90.0-test" && detail.host?.architecture == "aarch64")
        precondition(detail.host?.endpoints.count == 2 && detail.host?.derpRegion == 3)
        precondition(detail.host?.connectivity("WorkingIPv6") == "否" && detail.host?.connectivity("WorkingUDP") == "是")
        precondition(detail.host?.connectivity("UPnP") == "否" && detail.host?.connectivity("PCP") == "未提供")
        precondition(HeadplaneHostInfo.booleanText(.string("")) == "未提供")
        let fallback = HeadplaneHostInfo(.object(["HomeDERP": .number(0), "NetInfo": .object(["PreferredDERP": .number(5)])]))
        precondition(fallback.derpRegion == 5)
        var partial = data.object
        partial["stats"] = .null; partial["agent"] = .object([:])
        let fallbackDetail = try HeadplaneMachineDetail(.object(partial), nodeID: "2")
        precondition(fallbackDetail.host?.system == "linux 6.12.0" && fallbackDetail.agent == nil && !fallbackDetail.isAgent)
        let absent = try HeadplaneMachineDetail(payload("machineNoAgent", .machine("3")), nodeID: "3")
        precondition(absent.host == nil && absent.agent == nil && !absent.isAgent && absent.domain.isEmpty)
        rejects { _ = try HeadplaneMachineDetail(data, nodeID: "3") }
        rejects { _ = try HeadplaneMachineDetail(.object([:]), nodeID: "2") }
        for id in ["", "../login", "2/3", "2?x=1", "2%2F3", "２"] {
            rejects { _ = try connection.request(.machine(id)) }
        }
        let request = try connection.request(.machine("18446744073709551615"))
        precondition(request.url?.path == "/admin/machines/18446744073709551615.data")
        print("PASS independent device detail fields, optional Agent data and safe device URLs")
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
        let taggedFields = try HeadplaneKeyCreation.fields(userID: "1", tags: "server, tag:home，server\n tag:router", days: 7, reusable: true, ephemeral: false)
        precondition(taggedFields["acl_tags"] == "tag:server,tag:home,tag:router")
        let untaggedFields = try HeadplaneKeyCreation.fields(userID: "1", tags: " , \n", days: 1, reusable: false, ephemeral: true)
        precondition(untaggedFields["acl_tags"] == "" && untaggedFields["ephemeral"] == "on")
        for invalid in ["tag:", "bad tag", "tag:1server", "tag:server/home"] {
            rejects { _ = try HeadplaneKeyCreation.fields(userID: "1", tags: invalid, days: 1, reusable: false, ephemeral: false) }
        }
        rejects { _ = try HeadplaneKeyCreation.fields(userID: "", tags: " , \n", days: 1, reusable: false, ephemeral: false) }
        let tagOnly = try HeadplaneKeyCreation.fields(userID: "", tags: "server,tag:server", days: 45, reusable: true, ephemeral: true)
        precondition(tagOnly["user_id"] == nil && tagOnly["acl_tags"] == "tag:server" && tagOnly["expiry"] == "45")
        precondition(tagOnly["reusable"] == "on" && tagOnly["ephemeral"] == "on")
        let customDuration = try HeadplaneKeyCreation.duration(" 45 ")
        precondition(customDuration == 45)
        for invalid in ["", "0", "-1", "1.5", "1e2", "12days", "9999999999999999999999", "365001"] {
            rejects { _ = try HeadplaneKeyCreation.duration(invalid) }
        }
        for invalid in [0, -1, Int.max] {
            rejects { _ = try HeadplaneKeyCreation.fields(userID: "1", tags: "", days: invalid, reusable: false, ephemeral: false) }
        }
        WireProtocol.respond { request in
            precondition(request.url!.path == "/admin/settings/auth-keys.data")
            precondition(WireProtocol.body(request) == "acl_tags=tag%3Aserver&action_id=add_preauthkey&ephemeral=on&expiry=45&reusable=on")
            return (200, [:], created)
        }
        _ = try await client.submit(.keys, fields: tagOnly)
        WireProtocol.respond { request in
            precondition(request.url!.path == "/admin/settings/auth-keys.data" && request.httpMethod == "POST")
            precondition(WireProtocol.body(request) == "acl_tags=tag%3Aserver%2Ctag%3Ahome%2Ctag%3Arouter&action_id=add_preauthkey&ephemeral=off&expiry=7&reusable=on&user_id=1")
            return (200, [:], created)
        }
        let key = try await client.submit(.keys, fields: taggedFields)
        precondition(key["key"].text == "test-only-new-key")
        let taggedKey = try HeadplaneKey(.object(["id": .string("1"), "aclTags": .array([.string("tag:server")])]), user: .null)
        let untaggedKey = try HeadplaneKey(.object(["id": .string("2")]), user: .null)
        precondition(taggedKey.tags == ["tag:server"] && untaggedKey.tags.isEmpty)
        let machineDetail = try fixture("machineDetail")
        WireProtocol.respond { request in
            precondition(request.httpMethod == "GET" && request.url!.path == "/admin/machines/2.data")
            precondition(request.url!.query == "_routes=routes/machines/machine")
            precondition(request.value(forHTTPHeaderField: "Cookie") == "headplane=session")
            return (200, [:], machineDetail)
        }
        let detail = try HeadplaneMachineDetail(await client.read(.machine("2")), nodeID: "2")
        precondition(detail.node.name == "detail-router", "Details must use the independent loader, not the list")
        let missingDetail = try fixture("machineMissing")
        WireProtocol.respond { _ in (404, [:], missingDetail) }
        do { _ = try await client.read(.machine("2")); preconditionFailure() }
        catch let e as HeadplaneFailure { precondition(e.status == 404) }
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
        let dnsServerError = try fixture("dnsServerError")
        var dnsRequests = 0
        WireProtocol.respond { request in
            dnsRequests += 1
            precondition(request.url!.path == "/admin/dns.data" && request.url!.query == "_routes=routes/dns/overview")
            return (500, [:], dnsServerError)
        }
        await store.refresh(.dns)
        let dnsError = await store.errors[.dns], dnsData = await store.values[.dns]
        precondition(dnsError?.contains("HTTP 500") == true && dnsError?.contains("可能原因") == true && dnsData == nil)
        precondition(dnsRequests == 1, "DNS server errors must not trigger reauthentication or retries")
        let dnsDenied = Data(String(decoding: try fixture("denied"), as: UTF8.self)
            .replacingOccurrences(of: "routes/acls/overview", with: "routes/dns/overview").utf8)
        WireProtocol.respond { _ in (403, [:], dnsDenied) }
        do { _ = try await client.read(.dns); preconditionFailure() }
        catch let e as HeadplaneFailure { precondition(e.status == 403 && e.message == "Permission denied") }
        let longBody = "<html>DNS backend failed " + String(repeating: "诊断数据", count: 2_000) + " RESPONSE-END</html>"
        WireProtocol.respond { _ in
            (500, ["Content-Type": "text/html", "X-Request-ID": "dns-failure-500", "Set-Cookie": "headplane=new-private-session; Path=/admin"],
             Data((longBody + connection.apiKey + " session new-private-session").utf8))
        }
        do { _ = try await client.submit(.dns, fields: ["diagnostic": "REQUEST-END"]); preconditionFailure() }
        catch let e as HeadplaneFailure { precondition(e.status == 500 && e.outcomeUnknown) }
        let diagnostic = HakoLogStore.shared.snapshot().entries.first { $0.source == .headplane && $0.detail.contains("dns-failure-500") }!
        precondition(diagnostic.level == .error)
        for expected in ["方法：POST", "https://headplane.example.test/admin/dns.data", "diagnostic=REQUEST-END", "HTTP 状态：500", "dns-failure-500", "正文已省略"] {
            precondition(diagnostic.detail.contains(expected), "Missing HTTP diagnostic: \(expected)")
        }
        for secret in [connection.apiKey, "new-private-session", " session ", "RESPONSE-END</html>"] {
            precondition(!diagnostic.detail.contains(secret), "Credentials must be redacted")
        }
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

    @MainActor static func diagnostics() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WireProtocol.self]; config.httpCookieStorage = nil; config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var diagnosticConnection = connection
        diagnosticConnection.address = "https://headplane.example.test/custom/admin"
        diagnosticConnection.infoSecret = "test-only-info-secret"
        let client = try HeadplaneClient(connection: diagnosticConnection, session: session)
        let store = HeadplaneStore(client: client)
        var requests = 0
        WireProtocol.respond { request in
            requests += 1
            precondition(request.url!.path == "/custom/admin/healthz" && request.url!.query == nil)
            precondition(request.value(forHTTPHeaderField: "Cookie") == nil && request.value(forHTTPHeaderField: "Authorization") == nil)
            precondition(request.value(forHTTPHeaderField: "Accept") == "application/json")
            return (200, [:], Data(#"{"status":"OK"}"#.utf8))
        }
        await store.refresh(.health)
        precondition(store.health?.healthy == true && requests == 1)
        WireProtocol.respond { _ in (500, [:], Data(#"{"status":"ERROR"}"#.utf8)) }
        await store.refresh(.health)
        precondition(store.health?.healthy == false && store.errors[.health] == nil, "An explicit unhealthy response is a valid health result")
        WireProtocol.respond { _ in throw URLError(.timedOut) }
        await store.refresh(.health)
        precondition(store.health == nil && store.updated[.health] == nil && store.errors[.health] != nil)
        for (status, body) in [(200, "<html>Login</html>"), (500, "{}"), (200, #"{"status":"ERROR"}"#), (404, "{}")] {
            WireProtocol.respond { _ in (status, [:], Data(body.utf8)) }
            await store.refresh(.health)
            precondition(store.health == nil && store.errors[.health] != nil, "Unknown responses must not be reported healthy or unhealthy")
        }
        WireProtocol.respond { request in
            precondition(request.url!.path == "/custom/admin/api/info" && request.url!.query == nil)
            precondition(request.value(forHTTPHeaderField: "Cookie") == nil)
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-only-info-secret")
            return (200, [:], Data(#"{"status":"healthy","headplane_version":"0.8.2","headscale_canonical_version":"0.29.2","internal_versions":{"node":"25.9.0","openssl":"3.5","unexpected":"ignore"}}"#.utf8))
        }
        await store.refresh(.serverInfo)
        precondition(store.serverInfo?.headplaneVersion == "0.8.2" && store.serverInfo?.headscaleVersion == "0.29.2")
        precondition(store.serverInfo?.runtimeVersions.count == 2)
        requests = 0
        WireProtocol.respond { _ in requests += 1; return (403, [:], Data()) }
        await store.refresh(.serverInfo)
        precondition(store.serverInfo == nil && requests == 1 && store.errors[.serverInfo]?.contains("403") == true, "Info auth failures must not retry API Key login")
        let noSecretClient = try HeadplaneClient(connection: connection, session: session)
        do { _ = try await noSecretClient.read(.serverInfo); preconditionFailure() }
        catch let failure as HeadplaneFailure { precondition(failure.message.contains("info_secret")) }
        precondition(requests == 1, "Missing info secret must not send the API Key as a substitute")
        let unhealthyInfo = try JSONDecoder().decode(HeadplaneJSON.self, from: Data(#"{"status":"unhealthy","headplane_version":"0.8.2","headscale_canonical_version":"unknown"}"#.utf8))
        let info = try HeadplaneServerInfo(unhealthyInfo)
        precondition(!info.healthy && info.headscaleVersion == "未获取到")
        rejects { _ = try HeadplaneServerInfo(.object([:])) }
        requests = 0
        WireProtocol.respond { _ in requests += 1; return (302, ["Location": "https://other.example.test/api/info"], Data()) }
        do { _ = try await client.read(.serverInfo); preconditionFailure() }
        catch let failure as HeadplaneFailure { precondition(failure.status == 302 && requests == 1) }
        let settings = try fixture("serverSettings"), capabilities = try fixture("serverCapabilities")
        WireProtocol.respond { request in
            precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
            if request.url!.path == "/custom/admin/login" {
                precondition(!WireProtocol.body(request).contains("info-secret"))
                return (302, ["Location": "/custom/admin/machines", "Set-Cookie": "headplane=session; Path=/custom/admin; Secure; HttpOnly"], Data())
            }
            precondition(request.url!.path == "/custom/admin/settings.data")
            precondition(request.value(forHTTPHeaderField: "Cookie") == "headplane=session")
            if request.url!.query == "_routes=layout/app" { return (200, [:], capabilities) }
            precondition(request.url!.query == "_routes=routes/settings/overview")
            return (200, [:], settings)
        }
        await store.refresh(.settings); await store.refresh(.serverCapabilities)
        precondition(store.serverSettings?.configWritable == false && store.serverSettings?.hasOIDCConfig == true)
        precondition(store.serverCapabilities?.configReadable == true && store.serverCapabilities?.access["users"] == false)
        precondition(store.serverCapabilities?.access["unknown"] == nil)
        WireProtocol.respond { _ in throw URLError(.notConnectedToInternet) }
        await store.refresh(.settings); await store.refresh(.serverCapabilities)
        precondition(store.serverSettings == nil && store.serverCapabilities == nil)
        let errorBody = try JSONEncoder().encode(HeadplaneJSON.object(["routes/settings/overview": .object(["error": .object(["message": .string("bad test-only-info-secret and " + connection.apiKey)])])]))
        WireProtocol.respond { _ in (500, [:], errorBody) }
        do { _ = try await client.read(.settings); preconditionFailure() }
        catch let failure as HeadplaneFailure { precondition(!failure.message.contains("test-only-info-secret") && !failure.message.contains(connection.apiKey)) }
        print("PASS server health, isolated info-secret authentication, capability checks and stale-result clearing")
    }

    @MainActor static func detailStoreBehavior() async throws {
        let remote = try ControlledAccess(), store = HeadplaneStore(client: remote)
        async let first: Void = store.refresh(.machine("2"))
        async let second: Void = store.refresh(.machine("3"))
        _ = await (first, second)
        precondition(store.machines == nil && store.machineDetails.count == 2, "Each detail loads independently of the list")
        precondition(store.machineDetails["2"]?.node.name == "detail-router" && store.machineDetails["3"]?.node.name == "macbook")
        await remote.failDetail(500); await store.refresh(.machine("2"))
        precondition(store.machineDetails["2"] != nil && store.errors[.machine("2")] != nil, "Transient failures retain explicitly stale detail")
        await remote.failDetail(nil)
        let old = try payload("machineDetail", .machine("2"))
        var renamed = old.object, renamedNode = old["node"].object
        renamedNode["givenName"] = .string("renamed-router"); renamed["node"] = .object(renamedNode)
        await remote.configure(pause: true)
        let oldRead = Task { await store.refresh(.machine("2")) }
        for _ in 0..<10_000 { if await remote.waiting() { break }; await Task.yield() }
        let waiting = await remote.waiting(); precondition(waiting)
        await remote.setDetail(.object(renamed), id: "2")
        _ = try await store.mutate(.machines, revision: store.revision, fields: ["action_id": "rename", "node_id": "2", "name": "renamed-router"])
        precondition(store.machineDetails["2"]?.node.name == "renamed-router", "Successful edits reread the independent detail")
        await remote.release(old); await oldRead.value
        precondition(store.machineDetails["2"]?.node.name == "renamed-router", "Old detail reads cannot overwrite a post-mutation refresh")
        await remote.configure(failure: true)
        do { _ = try await store.mutate(.machines, revision: store.revision, fields: ["action_id": "expire", "node_id": "2"]); preconditionFailure() } catch {}
        precondition(store.machineDetails["2"] == nil && store.pending == .machines)
        await store.refresh(.machine("2"))
        precondition(store.pending == .machines, "Reading a detail cannot confirm an uncertain list mutation")
        await remote.configure(); await store.refresh(.machines)
        precondition(store.pending == nil)
        await remote.failDetail(404); await store.refresh(.machine("2"))
        precondition(store.machineDetails["2"] == nil && store.values[.machine("2")] == nil && store.updated[.machine("2")] == nil)
        precondition(store.machineDetails["3"] != nil && store.errors[.machine("2")]?.contains("404") == true)
        await remote.failDetail(403); await store.refresh(.machine("3"))
        precondition(store.machineDetails["3"] == nil && store.errors[.machine("3")]?.contains("403") == true)
        await remote.failDetail(nil); await store.refresh(.machine("2"))
        _ = try await store.mutate(.machines, revision: store.revision, fields: ["action_id": "delete", "node_id": "2"])
        precondition(store.machineDetails["2"] == nil, "Deleted details must not remain cached")
        print("PASS detail isolation, stale refresh recovery, mutation read-back and deleted/forbidden devices")
    }

    static func sshRouting() throws {
        let custom = try HeadplaneConnection(address: "https://headplane.example.test/custom/admin/", apiKey: "private-key").normalized()
        let url = try HeadplaneSSH.terminalURL(connection: custom, hostname: "home-router", username: " ubuntu ")
        precondition(url.absoluteString == "https://headplane.example.test/custom/admin/ssh/home-router?user=ubuntu")
        precondition(!url.absoluteString.contains(custom.apiKey))
        let prompted = try HeadplaneSSH.terminalURL(connection: custom, hostname: "home-router")
        precondition(prompted.query == nil)
        let escaped = try HeadplaneSSH.terminalURL(connection: custom, hostname: "home-router", username: "user&other=1")
        let items = URLComponents(url: escaped, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(items.count == 1 && items[0].value == "user&other=1")
        for invalid in ["", "../login", "router/other", "host?user=root", "-host", String(repeating: "a", count: 64)] {
            rejects { _ = try HeadplaneSSH.terminalURL(connection: custom, hostname: invalid) }
        }
        rejects { _ = try HeadplaneSSH.terminalURL(connection: custom, hostname: "router", username: "user\nroot") }
        for invalid in ["file:///etc/passwd", "javascript:alert(1)", "https://user:pass@example.test", "http://example.test"] {
            precondition(!HeadplaneSSH.allowsNavigation(URL(string: invalid)!, allowHTTP: false))
        }
        precondition(HeadplaneSSH.allowsNavigation(URL(string: "https://identity.example.test/login")!, allowHTTP: false))
        precondition(HeadplaneSSH.allowsNavigation(URL(string: "http://example.test/login")!, allowHTTP: true))
        for path in ["/custom/admin", "/custom/admin/", "/custom/admin/machines"] {
            precondition(HeadplaneSSH.isLoginReturn(URL(string: "https://headplane.example.test" + path)!, connection: custom))
        }
        for address in ["https://attacker.example.test/custom/admin", "https://headplane.example.test:444/custom/admin", "http://headplane.example.test/custom/admin", "https://headplane.example.test/custom/admin/oidc/callback"] {
            precondition(!HeadplaneSSH.isLoginReturn(URL(string: address)!, connection: custom))
        }
        print("PASS SSH hostname routing, custom prefixes, username escaping, credential isolation and OIDC return origin")
    }

    static func main() async throws {
        try sshRouting()
        try decoding(); try configuration(); try agentStatus(); try machineDetails(); try await networking(); try await storeBehavior(); try await detailStoreBehavior(); try await diagnostics()
        print("Headplane tests passed")
    }
}
