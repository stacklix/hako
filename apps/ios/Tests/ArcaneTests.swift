import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class ArcaneMockProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var handler: ((URLRequest) throws -> (Int, Data))?
    static func respond(_ block: @escaping (URLRequest) throws -> (Int, Data)) {
        lock.lock(); defer { lock.unlock() }
        handler = block
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            Self.lock.lock()
            let result: Result<(Int, Data), Error>
            do { result = .success(try Self.handler!(request)) }
            catch { result = .failure(error) }
            Self.lock.unlock()
            let (status, data) = try result.get()
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

@main struct ArcaneTests {
    static func main() async throws {
        func bytes(_ value: String) -> Data { Data(value.utf8) }
        func rejected(_ connection: ArcaneConnection) {
            do { _ = try connection.normalized(); fatalError("Invalid connection accepted") }
            catch is ArcaneFailure { }
            catch { fatalError("Unexpected validation error") }
        }
        let connection = ArcaneConnection(name: "NAS", address: "https://arcane.example.com/docker/api/", apiKey: "test-key")
        let normalized = try connection.normalized()
        precondition(normalized.address == "https://arcane.example.com/docker")
        let request = try normalized.request(["environments", "0", "containers", "abc", "redeploy"], method: "POST")
        precondition(request.url?.absoluteString == "https://arcane.example.com/docker/api/environments/0/containers/abc/redeploy")
        precondition(request.value(forHTTPHeaderField: "X-Api-Key") == "test-key")
        precondition(request.url?.absoluteString.contains("test-key") == false)
        let socket = try normalized.request(["environments", "0", "ws", "containers", "abc", "logs"], websocket: true)
        precondition(socket.url?.scheme == "wss" && socket.value(forHTTPHeaderField: "X-Api-Key") == "test-key")
        for address in ["http://nas.local:3552", "https://user:pass@arcane.example.com", "https://arcane.example.com?token=bad", "https://arcane.example.com/#login", "file:///etc/passwd", "https://arcane.example.com/a/../b"] {
            var invalid = connection; invalid.address = address; rejected(invalid)
        }
        var http = connection; http.address = "http://192.168.1.2:3552"; http.allowHTTP = true
        let normalizedHTTP = try http.normalized()
        precondition(normalizedHTTP.address == "http://192.168.1.2:3552")
        var badKey = connection; badKey.apiKey = "key\r\nHeader: injected"; rejected(badKey)
        for badID in ["../host", "..", "a/b", "x?api-key=leak", "x#fragment", ""] {
            do { _ = try connection.request(["environments", badID]); fatalError("Unsafe ID accepted") }
            catch is ArcaneFailure { }
        }

        let decoder = JSONDecoder()
        let summary = try decoder.decode(ArcaneContainer.self, from: bytes(#"{"id":"old","names":["/postgres"],"image":"postgres:16","state":"running","status":"Up 2 days (unhealthy)","labels":{"com.docker.compose.project":"hako"},"updateInfo":{"hasUpdate":true,"error":""}}"#))
        precondition(summary.name == "postgres" && summary.abnormal && !summary.stopped && summary.update?.hasUpdate == true && summary.project == "hako")
        let minimal = try decoder.decode(ArcaneContainerDetails.self, from: bytes(#"{"id":"new"}"#))
        precondition(minimal.id == "new" && minimal.state == nil)
        let details = try decoder.decode(ArcaneContainerDetails.self, from: bytes(#"{"id":"old","name":"/postgres","state":{"running":true,"status":"running","health":{"status":"unhealthy"}},"config":{"env":["PASSWORD=a=b"]},"networkSettings":{"networks":{"default":{"ipAddress":"172.20.0.3"}}},"ports":[{"privatePort":80,"publicPort":8080,"type":"tcp"}],"mounts":null}"#))
        precondition(details.displayName == "postgres" && details.state?.health?.status == "unhealthy" && details.ports?.first?.text == "8080 → 80/tcp")
        let multiplePorts = try decoder.decode(ArcaneContainerDetails.self, from: bytes(#"{"id":"ports","ports":[{"privatePort":80,"publicPort":0,"type":"tcp"},{"privatePort":443,"type":"tcp"},{"privatePort":53,"publicPort":1053,"type":"udp"}]}"#))
        precondition(multiplePorts.portsText == "1053 → 53/udp\n80/tcp\n443/tcp",
                     "Unmapped ports must omit host port zero; all ports share one multiline value")
        let emptyPorts = try decoder.decode(ArcaneContainerDetails.self, from: bytes(#"{"id":"no-ports","ports":[]}"#))
        precondition(emptyPorts.portsText == nil && minimal.portsText == nil)
        precondition(details.portsText == "8080 → 80/tcp")
        func portDetails(_ bindings: [[String: Any]]) throws -> ArcaneContainerDetails {
            try decoder.decode(ArcaneContainerDetails.self, from: JSONSerialization.data(withJSONObject: ["id": "port-bindings", "ports": bindings]))
        }
        let caddyBindings: [[String: Any]] = [
            ["privatePort": 443, "publicPort": 443, "type": "udp", "ip": "::"],
            ["privatePort": 80, "publicPort": 80, "type": "tcp", "ip": "0.0.0.0"],
            ["privatePort": 2019, "type": "tcp"],
            ["privatePort": 443, "publicPort": 443, "type": "tcp", "ip": "::"],
            ["privatePort": 80, "publicPort": 80, "type": "tcp", "ip": "::"],
            ["privatePort": 443, "publicPort": 443, "type": "udp", "ip": "0.0.0.0"],
            ["privatePort": 443, "publicPort": 443, "type": "tcp", "ip": "0.0.0.0"]
        ]
        let expectedCaddyPorts = "80 → 80/tcp\n443 → 443/tcp\n443 → 443/udp\n2019/tcp"
        for offset in caddyBindings.indices {
            let shuffled = Array(caddyBindings.dropFirst(offset)) + Array(caddyBindings.prefix(offset))
            let forward = try portDetails(shuffled)
            let reversed = try portDetails(Array(shuffled.reversed()))
            precondition(forward.portsText == expectedCaddyPorts && reversed.portsText == expectedCaddyPorts,
                         "Dual-stack mappings must display once, in numeric order regardless of response order")
        }
        let distinctBindings = try portDetails([
            ["privatePort": 80, "publicPort": 8081, "type": "tcp"],
            ["privatePort": 80, "publicPort": 8080, "type": "TCP"],
            ["privatePort": 80, "publicPort": 8080],
            ["privatePort": 80, "publicPort": 8080, "type": "udp"],
            ["privatePort": 80, "publicPort": 8080, "type": "tcp", "ip": "127.0.0.1"],
            ["privatePort": 80, "publicPort": 8080, "type": "tcp", "ip": "::1"],
            ["privatePort": 2019, "publicPort": 0],
            ["privatePort": 2019, "type": "tcp"]
        ])
        precondition(distinctBindings.portsText == "8080 → 80/tcp\n127.0.0.1:8080 → 80/tcp\n[::1]:8080 → 80/tcp\n8081 → 80/tcp\n8080 → 80/udp\n2019/tcp",
                     "Keep different host ports, protocols and specific bind addresses; normalize default protocol and unmapped zero")
        precondition(ArcaneAction.restart.confirmationTitle == "重启容器？" && ArcaneAction.stop.confirmationTitle == "停止容器？")
        precondition(ArcaneOperationStatus(action: .redeploy, running: true).text == "更新中…")
        precondition(ArcaneOperationStatus(action: .redeploy, running: false).text == "更新结果待确认")
        func restartState(_ id: String = "restart-proof", startedAt: String, status: String = "running") throws -> ArcaneContainerDetails {
            try decoder.decode(ArcaneContainerDetails.self, from: JSONSerialization.data(withJSONObject:
                ["id": id, "state": ["status": status, "running": status == "running", "startedAt": startedAt]]))
        }
        var restartProof = ArcanePendingOperation(connectionID: "connection", environmentID: "0", environmentName: "local",
            containerID: "restart-proof", containerName: "service", action: .restart, previousStartedAt: "2026-10-29T16:00:00Z")
        let unchangedStart = try restartState(startedAt: "2026-10-29T16:00:00Z")
        let changedStart = try restartState(startedAt: "2026-10-29T17:00:00.123456789Z")
        precondition(!restartProof.restartObserved(in: unchangedStart) && restartProof.restartObserved(in: changedStart))
        let wrongContainer = try restartState("other", startedAt: "2026-10-29T17:00:00Z")
        let stillRestarting = try restartState(startedAt: "2026-10-29T17:00:00Z", status: "restarting")
        let invalidStart = try restartState(startedAt: "invalid")
        precondition(!restartProof.restartObserved(in: wrongContainer) && !restartProof.restartObserved(in: stillRestarting) && !restartProof.restartObserved(in: invalidStart))
        let legacy = try decoder.decode(ArcanePendingOperation.self, from: bytes(#"{"id":"legacy","connectionID":"connection","environmentID":"0","environmentName":"local","containerID":"restart-proof","containerName":"service","action":"restart","startedAt":0}"#))
        precondition(legacy.previousStartedAt == nil && legacy.restartObserved(in: changedStart), "Old pending records must remain readable")
        restartProof.previousStartedAt = nil
        restartProof.startedAt = Date(timeIntervalSince1970: 4_000_000_000)
        precondition(!restartProof.restartObserved(in: changedStart), "A legacy record must not accept a start older than its request")

        let rawStats = bytes(#"{"read":"2026-10-29T12:00:00.000000000Z","cpu_stats":{"cpu_usage":{"total_usage":300},"system_cpu_usage":2000,"online_cpus":4},"precpu_stats":{"cpu_usage":{"total_usage":200},"system_cpu_usage":1000},"memory_stats":{"usage":4000,"limit":10000,"stats":{"inactive_file":1000}},"networks":{"eth0":{"rx_bytes":1000,"tx_bytes":2000},"eth1":{"rx_bytes":3000,"tx_bytes":4000}}}"#)
        let sample = try ArcaneResourceSample.parse(rawStats)
        precondition(sample.cpuPercent == 40 && sample.memoryUsageBytes == 3000 && sample.memoryPercent == 30)
        precondition(sample.networkRxBytes == 4000 && sample.networkTxBytes == 6000 && sample.sourceDate != nil)
        let next = ArcaneResourceSample(cpuPercent: nil, memoryUsageBytes: nil, memoryLimitBytes: nil, sampleTime: nil, networkRxBytes: 8000, networkTxBytes: 12000)
        let traffic = ArcaneNetworkTraffic(previous: sample, current: next, elapsed: 2)
        precondition(traffic.uploadBytesPerSecond == 3000 && traffic.downloadBytesPerSecond == 2000)
        precondition(traffic.receivedBytes == 8000 && traffic.transmittedBytes == 12000)
        precondition(ArcaneNetworkTraffic(previous: nil, current: next, elapsed: 1).uploadBytesPerSecond == nil)
        precondition(ArcaneNetworkTraffic(previous: next, current: sample, elapsed: 1).uploadBytesPerSecond == nil)
        precondition(ArcaneNetworkTraffic(previous: sample, current: next, elapsed: 0).downloadBytesPerSecond == nil)
        precondition(ArcaneNetworkTraffic(previous: sample, current: next, elapsed: 31).downloadBytesPerSecond == nil)
        precondition(ArcaneNetworkTraffic.speed(1_500_000) == "1.5 MB/s")
        let missing = try ArcaneResourceSample.parse(bytes(#"{"cpu_stats":{},"memory_stats":{}}"#))
        precondition(missing.cpuPercent == nil && missing.memoryPercent == nil && missing.networkRxBytes == nil)
        let structured = try ArcaneLogDecoder.lines(bytes(#"{"timestamp":"now","level":"info","message":"ready"}"#))
        precondition(structured == ["now info ready"])
        let plainLogs = try ArcaneLogDecoder.lines(bytes("a\nb\n"))
        precondition(plainLogs == ["a", "b"])
        let applicationError = try ArcaneLogDecoder.lines(bytes(#"{"level":"error","message":"{\"error\":\"application failed\"}"}"#))
        precondition(applicationError == [#"error {"error":"application failed"}"#])
        do { _ = try ArcaneLogDecoder.lines(bytes(#"{"error":"upstream failed"}"#)); fatalError("Stream error accepted") }
        catch is ArcaneFailure { }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArcaneMockProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = try ArcaneClient(connection: connection, session: session)
        func failure(status: Int? = nil, unknown: Bool? = nil, _ action: () async throws -> Void) async {
            do { try await action(); fatalError("Expected request failure") }
            catch let error as ArcaneFailure {
                if let status { precondition(error.status == status) }
                if let unknown { precondition(error.outcomeUnknown == unknown) }
            } catch { fatalError("Unexpected request failure: \(error)") }
        }
        var starts: [String] = []
        ArcaneMockProtocol.respond { request in
            precondition(request.value(forHTTPHeaderField: "X-Api-Key") == "test-key")
            let start = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "start" }!.value!
            starts.append(start)
            return (200, bytes("{\"success\":true,\"data\":[{\"id\":\"\(start == "0" ? "first" : "second")\"}],\"pagination\":{\"totalItems\":2}}"))
        }
        let containers = try await client.containers("env-1")
        precondition(containers.map(\.id) == ["first", "second"] && starts == ["0", "1"])
        starts = []
        let environments = try await client.environments()
        precondition(environments.count == 2 && starts == ["0", "1"])
        ArcaneMockProtocol.respond { _ in (200, bytes(#"{"success":true,"data":[{"id":"same"}],"pagination":{"totalItems":2}}"#)) }
        await failure { _ = try await client.containers("0") }
        for status in [301, 401, 403, 404, 409, 429, 500] {
            ArcaneMockProtocol.respond { _ in (status, bytes("{}")) }
            await failure(status: status) { _ = try await client.details("0", id: "id") }
        }
        var mutationCount = 0
        ArcaneMockProtocol.respond { request in
            mutationCount += 1
            precondition(request.httpMethod == "POST" && request.url!.path.hasSuffix("/old/redeploy"))
            return (200, bytes(#"{"success":true,"data":{"id":"replacement"}}"#))
        }
        let replacement = try await client.perform(.redeploy, environment: "0", id: "old")
        precondition(replacement == "replacement" && mutationCount == 1)
        ArcaneMockProtocol.respond { _ in mutationCount += 1; throw URLError(.timedOut) }
        await failure(unknown: true) { _ = try await client.perform(.restart, environment: "0", id: "old") }
        precondition(mutationCount == 2, "A timed-out mutation must never retry")
        for body in [#"{"success":true,"data":{}}"#, #"{"success":false}"#, "{}", ""] {
            ArcaneMockProtocol.respond { _ in (200, bytes(body)) }
            await failure(unknown: true) { _ = try await client.perform(.redeploy, environment: "0", id: "old") }
        }
        ArcaneMockProtocol.respond { _ in (202, bytes(#"{"success":true,"data":{"id":"activity"}}"#)) }
        await failure(unknown: true) { _ = try await client.perform(.redeploy, environment: "0", id: "old") }
        ArcaneMockProtocol.respond { request in
            precondition(request.httpMethod == "DELETE")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            precondition(query.contains(URLQueryItem(name: "force", value: "false")) && query.contains(URLQueryItem(name: "volumes", value: "false")))
            return (204, Data())
        }
        let deleted = try await client.perform(.delete, environment: "0", id: "old")
        precondition(deleted == nil)
        ArcaneMockProtocol.respond { request in
            precondition(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "registry.example.com/team/app:latest")
            return (200, bytes(#"{"success":true,"data":{"hasUpdate":true,"containerUpdates":{"old":{"hasUpdate":false,"latestVersion":"policy-version"}}}}"#))
        }
        let update = try await client.checkUpdate("0", image: "registry.example.com/team/app:latest", containerID: "old")
        precondition(update.hasUpdate == false && update.latestVersion == "policy-version")
        precondition(client.redacted("example test-key output") == "example [已隐藏] output")

        let delegate = ArcaneSessionDelegate()
        var refused = false
        let redirectTask = session.dataTask(with: URL(string: "https://arcane.example.com")!)
        delegate.urlSession(session, task: redirectTask, willPerformHTTPRedirection: HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!, newRequest: URLRequest(url: URL(string: "https://other.example.com")!)) { refused = $0 == nil }
        precondition(refused)
        redirectTask.cancel()
        print("PASS: Arcane configuration/auth, pagination, DTOs, Docker stats, network rates/resets, logs, errors, mutation uncertainty/no-retry, replacement IDs, safe deletion and redirect refusal")
    }
}
