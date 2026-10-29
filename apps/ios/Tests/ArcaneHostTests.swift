import Foundation
import Combine

private final class HostMockProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var handler: ((URLRequest) -> (Int, Data))?
    static func respond(_ value: @escaping (URLRequest) -> (Int, Data)) {
        lock.lock(); defer { lock.unlock() }; handler = value
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let response = Self.handler!(request); Self.lock.unlock()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: response.0,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.1)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@MainActor private final class HostProbe {
    var infos: [String: CheckedContinuation<ArcaneHostInfo, Error>] = [:]
    var streams: [String: CheckedContinuation<Void, Error>] = [:]
    var consumers: [String: ArcaneHostData.Consumer] = [:]
    var ports: [String: CheckedContinuation<[ArcanePortMapping], Error>] = [:]
    func info(_ environment: String) async throws -> ArcaneHostInfo {
        try await withCheckedThrowingContinuation { infos[environment] = $0 }
    }
    func stream(_ environment: String, consume: @escaping ArcaneHostData.Consumer) async throws {
        consumers[environment] = consume
        try await withCheckedThrowingContinuation { streams[environment] = $0 }
    }
    func readPorts(_ environment: String) async throws -> [ArcanePortMapping] {
        try await withCheckedThrowingContinuation { ports[environment] = $0 }
    }
}

@main @MainActor struct ArcaneHostTests {
    static func main() async throws {
        func bytes(_ text: String) -> Data { Data(text.utf8) }
        let infoBytes = bytes(#"{"success":true,"Name":"host-a","NCPU":2,"MemTotal":4096,"OperatingSystem":"Debian","KernelVersion":"6.1","Architecture":"x86_64","ServerVersion":"28.0","apiVersion":"1.48","Driver":"overlay2","LoggingDriver":"json-file","DockerRootDir":"/var/lib/docker","Containers":8,"ContainersRunning":8,"ContainersStopped":0,"ContainersPaused":0,"Images":28}"#)
        let statsBytes = bytes(#"{"cpuUsage":1.5,"cpuCount":2,"memoryUsage":1024,"memoryTotal":4096,"diskUsage":100,"diskTotal":1000,"hostname":"host-a","architecture":"amd64","platform":"linux","gpus":[{"name":"GPU","index":0,"memoryUsed":1,"memoryTotal":4}]}"#)
        let info = try ArcaneHostInfo.parse(infoBytes)
        precondition(info.name == "host-a" && info.cpuCount == 2 && info.memoryTotal == 4096)
        precondition(info.serverVersion == "28.0" && info.running == 8 && info.stopped == 0 && info.images == 28)
        let stats = try ArcaneHostStats.parse(statsBytes)
        precondition(stats.cpuPercent == 1.5 && stats.memoryPercent == 25 && stats.diskPercent == 10)
        precondition(stats.gpus?.first?.name == "GPU")
        let partial = try ArcaneHostStats.parse(bytes(#"{"cpuUsage":0,"memoryTotal":0,"diskTotal":0}"#))
        precondition(partial.cpuPercent == 0 && partial.memoryPercent == nil && partial.diskPercent == nil)
        precondition(ArcaneHostStats.percent(-1) == nil && ArcaneHostStats.percent(.infinity) == nil)
        precondition(ArcaneHostStats.usagePercent(-1, 100) == nil && ArcaneHostStats.usagePercent(1, 0) == nil)
        precondition(ArcaneHostStats.usagePercent(110, 100) == 100)
        precondition(ArcaneHostFormat.bytes(nil) == "—" && ArcaneHostFormat.percent(nil) == "—")
        precondition(ArcaneHostFormat.byteCount(.infinity) == nil && ArcaneHostFormat.byteCount(Double(Int64.max)) == nil)
        func mapping(_ id: String, host: Int?, destination: Int, ip: String? = "0.0.0.0", transport: String = "tcp", published: Bool = true, owner: String = "caddy") -> ArcanePortMapping {
            ArcanePortMapping(id: id, containerId: owner, containerName: "/" + owner, hostIp: ip, hostPort: host,
                              containerPort: destination, transport: transport, isPublished: published)
        }
        let bindings = [
            mapping("tls-v6", host: 443, destination: 443, ip: "::"), mapping("http-v4", host: 80, destination: 80),
            mapping("private", host: nil, destination: 2019, published: false), mapping("tls-v4", host: 443, destination: 443),
            mapping("http-v6", host: 80, destination: 80, ip: "::"), mapping("quic", host: 443, destination: 443, transport: "udp"),
            mapping("local", host: 8080, destination: 80, ip: "127.0.0.1", owner: "app"),
            mapping("zero", host: 0, destination: 80), mapping("invalid", host: 70000, destination: 80),
            mapping("unpublished", host: 9999, destination: 80, published: false)
        ]
        let grouped = ArcaneContainerPorts.summarize(bindings)
        precondition(grouped.map(\.name) == ["app", "caddy"])
        precondition(grouped[0].ports.map(\.title) == ["8080 → 80/tcp"])
        precondition(grouped[1].ports.map(\.title) == ["80/tcp", "80 → 80/tcp", "443 → 443/tcp", "443 → 443/udp", "2019/tcp"])
        precondition(grouped[1].ports[1].bindingText == "绑定：0.0.0.0、::" && grouped[0].ports[0].bindingText == "绑定：127.0.0.1")
        precondition(grouped[1].ports[0].bindingText == "未映射到宿主机" && grouped[1].ports[4].bindingText == "未映射到宿主机")
        let reversed = ArcaneContainerPorts.summarize(Array(bindings.reversed()))
        precondition(reversed.map(\.id) == grouped.map(\.id) && reversed.flatMap { $0.ports.map(\.id) } == grouped.flatMap { $0.ports.map(\.id) },
                     "Group by container and sort ports numerically without changing on refresh")
        let internalOnly = ArcaneContainerPorts.summarize([mapping("private", host: nil, destination: 9000, published: false, owner: "private")])
        precondition(internalOnly.count == 1 && internalOnly[0].ports.map(\.title) == ["9000/tcp"], "Keep containers with only exposed ports")
        let distinct = ArcaneContainerPorts.summarize([
            mapping("a", host: 8080, destination: 80, owner: "a"), mapping("b", host: 8080, destination: 80, ip: "127.0.0.1", owner: "b"),
            mapping("c", host: 8080, destination: 81, owner: "a"), mapping("d", host: 8080, destination: 80, transport: "UDP", owner: "a")
        ])
        precondition(distinct.count == 2 && distinct[0].ports.count == 3 && distinct[1].ports.count == 1,
                     "Keep different containers, destinations and protocols")
        let sameNames = ArcaneContainerPorts.summarize([
            ArcanePortMapping(id: "a", containerId: "id-a", containerName: "same", hostIp: nil, hostPort: nil, containerPort: 80, transport: "tcp", isPublished: false),
            ArcanePortMapping(id: "b", containerId: "id-b", containerName: "same", hostIp: nil, hostPort: nil, containerPort: 80, transport: "tcp", isPublished: false)
        ])
        precondition(sameNames.map(\.id) == ["id-a", "id-b"], "Container IDs keep equal names separate")
        for invalid in ["{}", #"{"error":"denied"}"#, "not-json"] {
            do { _ = try ArcaneHostStats.parse(bytes(invalid)); fatalError("Invalid metrics accepted") }
            catch is ArcaneFailure { }
        }
        for invalid in ["{}", #"{"success":false,"Name":"host"}"#, #"{"success":true,"data":{"Name":"wrong-shape"}}"#] {
            do { _ = try ArcaneHostInfo.parse(bytes(invalid)); fatalError("Invalid host info accepted") }
            catch is ArcaneFailure { }
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HostMockProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = try ArcaneClient(connection: ArcaneConnection(name: "Test", address: "https://arcane.example/proxy", apiKey: "test-key"), session: session)
        HostMockProtocol.respond { request in
            precondition(request.httpMethod == "GET" && request.url?.path == "/proxy/api/environments/remote/system/docker/info")
            precondition(request.value(forHTTPHeaderField: "X-Api-Key") == "test-key")
            return (200, infoBytes)
        }
        let fetched = try await client.hostInfo("remote")
        precondition(fetched.name == "host-a")
        var portRequests = 0
        HostMockProtocol.respond { request in
            portRequests += 1
            precondition(request.httpMethod == "GET" && request.url?.path == "/proxy/api/environments/remote/ports")
            precondition(request.value(forHTTPHeaderField: "X-Api-Key") == "test-key")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            precondition(query.contains(URLQueryItem(name: "sort", value: "hostPort")))
            let start = query.first { $0.name == "start" }!.value!
            let rows = start == "0" ? #"[{"id":"a","containerId":"caddy","containerName":"/caddy","hostIp":"0.0.0.0","hostPort":80,"containerPort":80,"protocol":"tcp","isPublished":true},{"id":"b","containerId":"caddy","containerName":"/caddy","hostIp":"::","hostPort":80,"containerPort":80,"protocol":"tcp","isPublished":true}]"#
                : #"[{"id":"c","containerId":"caddy","containerName":"/caddy","containerPort":2019,"protocol":"tcp","isPublished":false}]"#
            precondition(start == "0" || start == "2")
            return (200, bytes("{\"success\":true,\"data\":\(rows),\"pagination\":{\"totalItems\":3}}"))
        }
        let fetchedPorts = try await client.hostPorts("remote")
        let fetchedGroups = ArcaneContainerPorts.summarize(fetchedPorts)
        precondition(portRequests == 2 && fetchedPorts.count == 3 && fetchedGroups.count == 1)
        precondition(fetchedGroups[0].ports.map(\.title) == ["80 → 80/tcp", "2019/tcp"])
        for environment in ["0", "remote"] {
            let request = try client.hostStatsRequest(environment)
            precondition(request.url?.scheme == "wss" && request.url?.path == "/proxy/api/environments/\(environment)/ws/system/stats")
            precondition(request.value(forHTTPHeaderField: "X-Api-Key") == "test-key" && request.url?.absoluteString.contains("test-key") == false)
            precondition(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "interval", value: "2")])
        }
        do { _ = try client.hostStatsRequest("../remote"); fatalError("Invalid environment accepted") }
        catch is ArcaneFailure { }
        HostMockProtocol.respond { _ in (403, Data()) }
        do { _ = try await client.hostInfo("remote"); fatalError("Forbidden host request accepted") }
        catch let error as ArcaneFailure { precondition(error.status == 403 && !error.outcomeUnknown) }
        do { _ = try await client.hostPorts("remote"); fatalError("Forbidden ports request accepted") }
        catch let error as ArcaneFailure { precondition(error.status == 403 && !error.outcomeUnknown) }

        let probe = HostProbe()
        let model = ArcaneHostData(readInfo: { _, environment in try await probe.info(environment) },
                                   readStats: { _, environment, consume in try await probe.stream(environment, consume: consume) },
                                   readPorts: { _, environment in try await probe.readPorts(environment) })
        let oldInfo = Task { await model.refresh(client: client, environment: "old") }
        try await wait { probe.infos["old"] != nil }
        let newInfo = Task { await model.refresh(client: client, environment: "new") }
        try await wait { probe.infos["new"] != nil }
        let newValue = try ArcaneHostInfo.parse(bytes(#"{"success":true,"Name":"host-b","NCPU":4}"#))
        probe.infos.removeValue(forKey: "new")!.resume(returning: newValue)
        await newInfo.value
        probe.infos.removeValue(forKey: "old")!.resume(returning: info)
        await oldInfo.value
        precondition(model.info?.name == "host-b" && !model.infoLoading && model.infoError == nil,
                     "An old environment response must not replace newer information")

        let oldPorts = Task { await model.refreshPorts(client: client, environment: "old-port") }
        try await wait { probe.ports["old-port"] != nil }
        let newPorts = Task { await model.refreshPorts(client: client, environment: "new-port") }
        try await wait { probe.ports["new-port"] != nil }
        probe.ports.removeValue(forKey: "new-port")!.resume(returning: [bindings[6]])
        await newPorts.value
        probe.ports.removeValue(forKey: "old-port")!.resume(returning: bindings)
        await oldPorts.value
        precondition(model.ports?.map(\.name) == ["app"] && model.ports?.first?.ports.map(\.title) == ["8080 → 80/tcp"] && !model.portsLoading && model.portsError == nil)
        let failedPorts = Task { await model.refreshPorts(client: client, environment: "new-port") }
        try await wait { probe.ports["new-port"] != nil }
        probe.ports.removeValue(forKey: "new-port")!.resume(throwing: ArcaneFailure(message: "forbidden", status: 403))
        await failedPorts.value
        precondition(model.ports?.first?.ports.map(\.title) == ["8080 → 80/tcp"] && model.portsError != nil && model.infoError == nil,
                     "Port permission errors retain the last list and don't overwrite system information errors")

        let oldStream = Task { await model.observe(client: client, environment: "old") }
        try await wait { probe.consumers["old"] != nil }
        let newStream = Task { await model.observe(client: client, environment: "new") }
        try await wait { probe.consumers["new"] != nil }
        try await probe.consumers["old"]!(statsBytes)
        precondition(model.sample == nil && model.sampledAt == nil)
        try await probe.consumers["new"]!(statsBytes)
        precondition(model.connected && model.sample?.cpuPercent == 1.5 && model.sampledAt != nil)
        oldStream.cancel()
        probe.streams.removeValue(forKey: "old")!.resume()
        await oldStream.value
        precondition(model.connected, "An old cancellation must not mark the new stream disconnected")
        newStream.cancel()
        probe.streams.removeValue(forKey: "new")!.resume()
        await newStream.value
        precondition(!model.connected && model.sample != nil, "Keep the last sample on disconnect, marked stale")

        var forbiddenSubscriptions = 0
        let forbidden = ArcaneHostData(readStats: { _, _, _ in
            forbiddenSubscriptions += 1
            throw ArcaneFailure(message: "没有 system:read 权限", status: 403)
        })
        await forbidden.observe(client: client, environment: "remote")
        precondition(forbiddenSubscriptions == 1 && !forbidden.connected && forbidden.streamError != nil,
                     "Permission failures must not trigger repeated subscriptions")
        print("PASS: host REST/WS auth, network port pagination/container grouping/exposed ports/deduplication, missing metrics, stale environment isolation, cancellation and permission failures")
    }

    private static func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        fatalError("Host request did not start")
    }
}
