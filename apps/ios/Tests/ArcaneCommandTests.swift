import Foundation

private final class TestTerminal: ArcaneTerminalChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [Data]
    private var sent: [Data] = []
    private var closed = false
    private var waiter: CheckedContinuation<Data, Error>?
    let hold: Bool
    let openError: Error?
    let failSend: Int?
    init(_ frames: [Data], hold: Bool = false, openError: Error? = nil, failSend: Int? = nil) {
        self.frames = frames; self.hold = hold; self.openError = openError; self.failSend = failSend
    }
    func open() async throws { if let openError { throw openError } }
    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !frames.isEmpty { let value = frames.removeFirst(); lock.unlock(); continuation.resume(returning: value) }
            else if hold && !closed { waiter = continuation; lock.unlock() }
            else { lock.unlock(); continuation.resume(throwing: URLError(.networkConnectionLost)) }
        }
    }
    private func record(_ data: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }; sent.append(data); return sent.count == failSend
    }
    func send(_ data: Data) async throws { if record(data) { throw URLError(.networkConnectionLost) } }
    func resize(columns: Int, rows: Int) async throws { }
    func close() {
        lock.lock(); closed = true; let continuation = waiter; waiter = nil; lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }
    var messages: [Data] { lock.lock(); defer { lock.unlock() }; return sent }
    var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }
}

private actor OutputProbe {
    private(set) var data = Data()
    func append(_ bytes: Data) { data.append(bytes) }
}

@main struct ArcaneCommandTests {
    static func main() async throws {
        func data(_ text: String) -> Data { Data(text.utf8) }
        func expectFailure(_ action: () throws -> Void) {
            do { try action(); fatalError("Expected validation failure") } catch is ArcaneFailure { } catch { fatalError("Wrong validation failure") }
        }
        precondition((try? ArcaneCommandDefinition.keys(in: "echo {{first}} {{second}} {{first}}")) == ["first", "second"])
        for invalid in ["echo {{bad-key}}", "echo {{unfinished", "echo '{{quoted}}'", "echo \"{{quoted}}\"", "echo prefix{{value}}", "echo {{value}}suffix", "cat <<EOF\n{{value}}\nEOF", "echo `cat {{value}}`"] {
            expectFailure { _ = try ArcaneCommandDefinition.keys(in: invalid) }
        }
        let template = "tool --value={{value}} --count {{count}}"
        let definition = ArcaneCommandDefinition(name: "Test", template: template, parameters: [
            ArcaneCommandParameter(key: "value", name: "Value"), ArcaneCommandParameter(key: "count", name: "Count", kind: .number, defaultValue: "3")
        ])
        let injection = "x'; $(touch /tmp/never); echo '汉字"
        let resolved = try definition.resolve(["value": injection, "count": "7"])
        precondition(resolved == "tool --value=" + ArcaneCommandDefinition.quote(injection) + " --count '7'")
        expectFailure { _ = try definition.resolve(["value": "ok", "count": "nan"]) }
        expectFailure { _ = try definition.resolve([:]) }
        let sensitive = ArcaneCommandDefinition(name: "Secret", template: "tool {{password}}", parameters: [ArcaneCommandParameter(key: "password", name: "Password", kind: .password, defaultValue: "never-save")])
        precondition((try? sensitive.validated())?.parameters[0].defaultValue.isEmpty == true)
        precondition((try? sensitive.resolve(["password": "private"], preview: true)) == "tool '[已隐藏]'")
        precondition(ArcaneCommandRedaction.text("prefix secret value", secrets: ["secret"]) == "prefix [已隐藏] value")
        precondition(ArcaneCommandRedaction.text("partial secr", secrets: ["secret"]) == "partial [已隐藏]")
        let caddy = ArcaneCommandDefinition.caddy
        precondition((try? caddy[0].resolve([:])) == "caddy validate --config '/etc/caddy/Caddyfile' --adapter 'caddyfile'")
        precondition((try? caddy[1].resolve(["config": "/etc/caddy/config.json", "adapter": "json"])) == "caddy reload --config '/etc/caddy/config.json' --address 'localhost:2019'")

        let details = try JSONDecoder().decode(ArcaneContainerDetails.self, from: data(#"{"id":"old","name":"/app","labels":{"com.docker.compose.project":"demo","com.docker.compose.service":"web"}}"#))
        let replacement = try JSONDecoder().decode(ArcaneContainerDetails.self, from: data(#"{"id":"new","name":"/demo-web-1","labels":{"com.docker.compose.project":"demo","com.docker.compose.service":"web"}}"#))
        let context = ArcaneCommandContext(connection: "connection", environment: "0", details: details)
        precondition(context.stableKey == ArcaneCommandContext(connection: "connection", environment: "0", details: replacement).stableKey)
        precondition(context.stableKey != ArcaneCommandContext(connection: "connection", environment: "remote", details: replacement).stableKey)

        var decoder = ArcaneExecDecoder(token: "token")
        let echo = try decoder.feed(data("echo 'literal \\036token:ready\\037'\r\n"))
        precondition(!echo.becameReady)
        let stream = data("\u{1e}token:ready\u{1f}中文 output\n\u{1e}token:exit:0\u{1f}")
        var output = Data(), codes: [Int] = [], ready = 0
        for byte in stream {
            let event = try decoder.feed(Data([byte])); if event.becameReady { ready += 1 }
            output.append(event.output); if let code = event.exitCode { codes.append(code) }
        }
        precondition(ready == 1 && codes == [0] && String(decoding: output, as: UTF8.self) == "中文 output\n")
        var failed = ArcaneExecDecoder(token: "token")
        expectFailure { _ = try failed.feed(data("\u{1e}token:setup-error\u{1f}")) }

        let channel = TestTerminal([data("banner"), data("\u{1e}token:ready\u{1f}"), data("line\n"), data("\u{1e}token:exit:7\u{1f}")])
        let probe = OutputProbe()
        let code = try await ArcaneCommandExecutor.run(channel: channel, command: "exit 7", token: "token") { await probe.append($0) }
        precondition(code == 7 && channel.messages.count == 2 && channel.isClosed)
        let result = await probe.data
        precondition(result == data("line\n"))
        for (channel, unknown, sends) in [
            (TestTerminal([], openError: ArcaneFailure(message: "denied", status: 403)), false, 0),
            (TestTerminal([data("\u{1e}token:setup-error\u{1f}")]), false, 1),
            (TestTerminal([data("\u{1e}token:ready\u{1f}"), data("partial output")]), true, 2),
            (TestTerminal([data("\u{1e}token:ready\u{1f}")], failSend: 2), true, 2)
        ] {
            do { _ = try await ArcaneCommandExecutor.run(channel: channel, command: "true", token: "token") { _ in }; fatalError("Expected socket failure") }
            catch let error as ArcaneFailure { precondition(error.outcomeUnknown == unknown) }
            precondition(channel.messages.count == sends && channel.isClosed, "Never retry command sends")
        }
        let idle = TestTerminal([data("\u{1e}token:ready\u{1f}")], hold: true)
        do { _ = try await ArcaneCommandExecutor.run(channel: idle, command: "true", seconds: 0, token: "token") { _ in }; fatalError("Timeout did not fire") }
        catch let error as ArcaneFailure { precondition(error.outcomeUnknown) }
        precondition(idle.isClosed)
        let noShell = TestTerminal([], hold: true)
        do {
            _ = try await ArcaneCommandExecutor.run(channel: noShell, command: "must-not-run", initializationSeconds: 0, token: "token") { _ in }
            fatalError("Shell initialization did not time out")
        } catch let error as ArcaneFailure { precondition(!error.outcomeUnknown) }
        precondition(noShell.isClosed && noShell.messages.count <= 1, "Initialization failure must not send the actual command")
        let connection = try ArcaneConnection(name: "Test", address: "https://example.com/proxy", apiKey: "private").normalized()
        let request = try ArcaneSocketTerminal.request(connection, environment: "remote", container: "container", shell: "/bin/sh", columns: 120, rows: 40)
        precondition(request.url?.scheme == "wss" && request.url?.path == "/proxy/api/environments/remote/ws/containers/container/terminal")
        precondition(request.value(forHTTPHeaderField: "X-Api-Key") == "private" && !request.url!.absoluteString.contains("private"))
        expectFailure { _ = try ArcaneSocketTerminal.request(connection, environment: "remote", container: "container", shell: "/bin/sh -c bad", columns: 80, rows: 24) }
        print("PASS: command templates/quoting/redaction/JSON, stable scope, split terminal records/UTF8, exit codes, auth, failed/uncertain sends, timeout and no retries")
    }
}
