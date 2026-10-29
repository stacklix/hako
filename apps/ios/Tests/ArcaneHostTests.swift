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
    func info(_ environment: String) async throws -> ArcaneHostInfo {
        try await withCheckedThrowingContinuation { infos[environment] = $0 }
    }
    func stream(_ environment: String, consume: @escaping ArcaneHostData.Consumer) async throws {
        consumers[environment] = consume
        try await withCheckedThrowingContinuation { streams[environment] = $0 }
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

        let probe = HostProbe()
        let model = ArcaneHostData(readInfo: { _, environment in try await probe.info(environment) },
                                   readStats: { _, environment, consume in try await probe.stream(environment, consume: consume) })
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
        print("PASS: host REST/WS paths and auth, flat Docker info, missing metrics, percentages, stale environment isolation, stream cancellation and permission failures")
    }

    private static func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        fatalError("Host request did not start")
    }
}
