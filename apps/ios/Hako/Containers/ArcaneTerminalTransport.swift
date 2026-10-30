import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

protocol ArcaneTerminalChannel: AnyObject, Sendable {
    func open() async throws
    func receive() async throws -> Data
    func send(_ data: Data) async throws
    func resize(columns: Int, rows: Int) async throws
    func checkConnection() async throws
    func close()
}

extension ArcaneTerminalChannel {
    func checkConnection() async throws { }
}

// A missing pong must have a deadline even if Foundation never calls back.
enum ArcaneTerminalPing {
    static func wait(seconds: UInt64 = 5, send: @Sendable (@escaping @Sendable (Error?) -> Void) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let pending = ArcanePingCompletion(continuation)
            let timer = Task {
                do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) } catch { return }
                pending.finish(URLError(.timedOut))
            }
            send { error in timer.cancel(); pending.finish(error) }
        }
        try Task.checkCancellation()
    }
}

private final class ArcanePingCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
    func finish(_ error: Error?) {
        lock.lock(); let saved = continuation; continuation = nil; lock.unlock()
        if let error { saved?.resume(throwing: error) } else { saved?.resume() }
    }
}

struct ArcaneTerminalClosed: LocalizedError {
    var errorDescription: String? { "终端会话已结束。" }
}

struct ArcaneShellUnavailable: LocalizedError {
    var errorDescription: String? { "所选 Shell 不存在或无法启动。" }
}

struct ArcaneShellSession: Sendable {
    let channel: any ArcaneTerminalChannel
    let shell: String
    let available: [String]
    let output: Data
}

enum ArcaneShellDiscovery {
    static let candidates = ["/bin/sh", "/bin/bash", "/bin/ash", "/bin/zsh", "/usr/bin/sh", "/usr/bin/bash", "/usr/bin/ash", "/usr/bin/zsh"]
    static func cacheKey(_ context: ArcaneCommandContext) -> String { context.stableKey + ".shell" }

    static func connect(preferred: String, fallback: Bool,
                        factory: @Sendable (String) throws -> any ArcaneTerminalChannel) async throws -> ArcaneShellSession {
        let paths = [preferred] + (fallback ? candidates.filter { $0 != preferred } : [])
        for path in paths {
            try Task.checkCancellation()
            let channel = try factory(path)
            do {
                let result = try await probe(channel: channel, shell: path)
                return ArcaneShellSession(channel: channel, shell: path, available: result.available, output: result.output)
            } catch {
                channel.close()
                try Task.checkCancellation()
                // Authentication, network and timeout failures are not evidence
                // that the image lacks a shell, and must not trigger fallback.
                guard error is ArcaneShellUnavailable || error is ArcaneTerminalClosed else { throw error }
            }
        }
        throw ArcaneFailure(message: fallback ? "未找到可用 Shell。此容器可能没有安装 Shell，可尝试自定义路径。" : "所选 Shell 不存在或无法启动，请选择其他 Shell。")
    }

    static func probe(channel: any ArcaneTerminalChannel, shell: String, seconds: UInt64 = 8,
                      token: String = UUID().uuidString.replacingOccurrences(of: "-", with: "")) async throws -> (available: [String], output: Data) {
        let paths = [shell] + candidates.filter { $0 != shell }
        let script = "export TERM=xterm-256color; printf '\\036\(token):shells:'; for p in \(paths.map(ArcaneCommandDefinition.quote).joined(separator: " ")); do if [ -x \"$p\" ]; then printf '%s,' \"$p\"; fi; done; printf '\\037'\r"
        let marker = Data("\u{1e}\(token):shells:".utf8)
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: (available: [String], output: Data).self) { group in
                group.addTask {
                    try await channel.open()
                    try await channel.send(Data(script.utf8))
                    var bytes = Data()
                    while true {
                        try Task.checkCancellation()
                        bytes.append(try await channel.receive())
                        if let start = bytes.range(of: marker), let end = bytes[start.upperBound...].firstIndex(of: 0x1f) {
                            let found = String(decoding: bytes[start.upperBound..<end], as: UTF8.self).split(separator: ",").map(String.init)
                            let available = paths.filter { found.contains($0) || $0 == shell }
                            return (available, Data(bytes[bytes.index(after: end)...]))
                        }
                        guard bytes.count <= 65_536 else { throw ArcaneFailure(message: "无法确认 Shell 启动状态，终端初始化输出过长。") }
                    }
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                    channel.close()
                    throw ArcaneFailure(message: "Shell 探测超时，请检查终端连接；超时不代表容器没有 Shell。")
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        } onCancel: { channel.close() }
    }
}

final class ArcaneSocketTerminal: ArcaneTerminalChannel, @unchecked Sendable {
    private let socket: URLSessionWebSocketTask
    deinit { socket.cancel(with: .goingAway, reason: nil) }
    init(client: ArcaneClient, environment: String, container: String, shell: String = "/bin/sh", columns: Int = 80, rows: Int = 24) throws {
        socket = client.session.webSocketTask(with: try Self.request(client.connection, environment: environment, container: container, shell: shell, columns: columns, rows: rows))
        socket.maximumMessageSize = 1_048_576
    }
    static func request(_ connection: ArcaneConnection, environment: String, container: String, shell: String, columns: Int, rows: Int) throws -> URLRequest {
        guard shell.hasPrefix("/"), shell.count <= 256, !shell.contains(where: { $0.isWhitespace || $0.asciiValue.map { $0 < 32 || $0 == 127 } == true }) else {
            throw ArcaneFailure(message: "请填写 Shell 的容器内绝对路径，不包含参数。")
        }
        return try connection.request(["environments", environment, "ws", "containers", container, "terminal"],
            query: [URLQueryItem(name: "shell", value: shell), URLQueryItem(name: "cols", value: String(max(2, min(1000, columns)))),
                    URLQueryItem(name: "rows", value: String(max(2, min(1000, rows))))], websocket: true)
    }
    func open() async throws {
        socket.resume()
        // The first send/receive performs the handshake. Do not gate stdin on
        // a pong: some proxies do not forward control frames promptly.
        try Task.checkCancellation()
    }
    func receive() async throws -> Data {
        do {
            switch try await socket.receive() {
            case .data(let data): return data
            case .string(let text):
                if text.hasPrefix("Error creating exec:") || text.hasPrefix("Error attaching to exec:") {
                    let lower = text.lowercased()
                    if lower.contains("no such file or directory") || lower.contains("executable file not found") || lower.contains("not found in $path") {
                        throw ArcaneShellUnavailable()
                    }
                    throw ArcaneFailure(message: "无法启动容器终端，所选 Shell 可能不存在或无法执行。\n" + String(text.prefix(2000)))
                }
                return Data(text.utf8)
            @unknown default: return Data()
            }
        } catch let failure as ArcaneFailure { throw failure }
        catch let failure as ArcaneShellUnavailable { throw failure }
        catch { throw mapped(error) }
    }
    func send(_ data: Data) async throws {
        guard data.count <= 1_048_576 else { throw ArcaneFailure(message: "单次终端输入超过 1 MB。") }
        do { try await socket.send(.data(data)) } catch { throw mapped(error) }
    }
    func resize(columns: Int, rows: Int) async throws {
        let data = try JSONSerialization.data(withJSONObject: ["type": "resize", "cols": max(2, min(1000, columns)), "rows": max(2, min(1000, rows))])
        do { try await socket.send(.string(String(decoding: data, as: UTF8.self))) } catch { throw mapped(error) }
    }
    func close() { socket.cancel(with: .goingAway, reason: nil) }
    func checkConnection() async throws {
        do { try await ArcaneTerminalPing.wait { [socket] completion in socket.sendPing(pongReceiveHandler: completion) } }
        catch { throw mapped(error) }
    }
    private func mapped(_ error: Error) -> Error {
        if Task.isCancelled { return CancellationError() }
        if socket.closeCode == .normalClosure { return ArcaneTerminalClosed() }
        let status = (socket.response as? HTTPURLResponse)?.statusCode
        let message: String
        switch status {
        case 401: message = "API Key 无效或已过期。"
        case 403: message = "没有当前环境的 containers:exec 权限。"
        case 404: message = "容器或终端接口不存在，请刷新容器并核对 Arcane 版本。"
        default: message = "终端连接已断开，请检查容器、网络及代理的 WebSocket 支持。"
        }
        return ArcaneFailure(message: message, status: status == 101 ? nil : status)
    }
}

// Control records use actual RS/US bytes, so echoed shell source (with literal
// \\036/\\037) cannot be mistaken for a successful command or a ready session.
struct ArcaneExecDecoder {
    let token: String
    private(set) var ready = false
    private var buffer = Data()
    init(token: String) { self.token = token }
    struct Event { var becameReady = false; var output = Data(); var exitCode: Int? }
    mutating func feed(_ data: Data) throws -> Event {
        buffer.append(data)
        var event = Event()
        if !ready {
            let marker = Data("\u{1e}\(token):ready\u{1f}".utf8)
            if buffer.range(of: Data("\u{1e}\(token):setup-error\u{1f}".utf8)) != nil { throw ArcaneFailure(message: "容器终端不能关闭输入回显（需要 stty），尚未执行命令。") }
            guard let range = buffer.range(of: marker) else {
                if buffer.count > 16_384 { throw ArcaneFailure(message: "容器 Shell 未完成初始化，尚未执行命令。") }
                return event
            }
            buffer.removeSubrange(buffer.startIndex..<range.upperBound); ready = true; event.becameReady = true
        }
        let prefix = Data("\u{1e}\(token):exit:".utf8)
        if let range = buffer.range(of: prefix) {
            event.output = Data(buffer[..<range.lowerBound])
            buffer.removeSubrange(buffer.startIndex..<range.lowerBound)
            if let end = buffer.firstIndex(of: 0x1f) {
                let start = buffer.index(buffer.startIndex, offsetBy: prefix.count)
                let number = String(decoding: buffer[start..<end], as: UTF8.self)
                guard let code = Int(number), (0...255).contains(code) else { throw ArcaneFailure(message: "命令返回的退出码无效。", outcomeUnknown: true) }
                event.exitCode = code; buffer.removeAll()
            } else if buffer.count > prefix.count + 4 { throw ArcaneFailure(message: "命令完成记录无效。", outcomeUnknown: true) }
            return event
        }
        // Keep a possible marker prefix, including records split across frames.
        var keep = 0
        let maxKeep = min(buffer.count, prefix.count - 1)
        if maxKeep > 0 {
            for count in stride(from: maxKeep, through: 1, by: -1) where buffer.suffix(count).elementsEqual(prefix.prefix(count)) { keep = count; break }
        }
        let count = buffer.count - keep
        if count > 0 { event.output = Data(buffer.prefix(count)); buffer.removeFirst(count) }
        return event
    }
}

enum ArcaneCommandExecutor {
    static func script(_ command: String, token: String) throws -> String {
        let script = "sh -c \(ArcaneCommandDefinition.quote(command)) </dev/null; hako_exit=$?; printf '\\036\(token):exit:%s\\037' \"$hako_exit\"; exit\n"
        guard script.utf8.count <= 3500 else { throw ArcaneFailure(message: "展开后的命令过长，请缩短模板或参数。") }
        return script
    }
    static func run(channel: any ArcaneTerminalChannel, command: String, seconds: UInt64 = 120,
                    initializationSeconds: UInt64 = 10,
                    token: String = UUID().uuidString.replacingOccurrences(of: "-", with: ""),
                    progress: @escaping @Sendable (String) async -> Void = { _ in },
                    consume: @escaping @Sendable (Data) async -> Void) async throws -> Int {
        let script = try script(command, token: token)
        let state = ArcaneExecutionState()
        return try await withTaskCancellationHandler {
            defer { channel.close() }
            return try await withThrowingTaskGroup(of: Int.self) { group in
                group.addTask {
                    var sent = false
                    do {
                        try Task.checkCancellation()
                        await progress("正在连接终端…")
                        try await channel.open()
                        await progress("正在初始化 Shell…")
                        try await channel.send(Data("PS1=; PS2=; stty -echo 2>/dev/null && printf '\\036\(token):ready\\037' || { printf '\\036\(token):setup-error\\037'; exit; }\n".utf8))
                        var decoder = ArcaneExecDecoder(token: token)
                        while !Task.isCancelled {
                            let event = try decoder.feed(try await channel.receive())
                            if event.becameReady {
                                // A failed send is uncertain too: the peer may have received it.
                                guard await state.beginSending() else {
                                    throw ArcaneFailure(message: "Shell 初始化超时，尚未执行命令。")
                                }
                                sent = true
                                await progress("正在执行命令…")
                                try await channel.send(Data(script.utf8))
                            }
                            if !event.output.isEmpty { await consume(event.output) }
                            if let code = event.exitCode { return code }
                        }
                        throw CancellationError()
                    } catch {
                        let failure = error as? ArcaneFailure
                        throw ArcaneFailure(message: failure?.message ?? "未能取得命令的完整执行结果。", status: failure?.status, outcomeUnknown: sent || failure?.outcomeUnknown == true)
                    }
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                    channel.close()
                    throw ArcaneFailure(message: "等待执行结果超时，请核对容器状态和输出，不会自动重新执行。", outcomeUnknown: true)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: initializationSeconds * 1_000_000_000)
                    if !(await state.expireInitialization()) { // The execution deadline still applies.
                        try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                        throw CancellationError()
                    }
                    channel.close()
                    throw ArcaneFailure(message: "Shell 初始化超时，尚未执行命令。请确认容器包含 /bin/sh 和 stty，并检查 Arcane 终端连接。")
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        } onCancel: { channel.close() }
    }
}

private actor ArcaneExecutionState {
    private(set) var wasSent = false
    private var expired = false
    func beginSending() -> Bool {
        guard !expired else { return false }
        wasSent = true; return true
    }
    func expireInitialization() -> Bool {
        guard !wasSent else { return false }
        expired = true; return true
    }
}
