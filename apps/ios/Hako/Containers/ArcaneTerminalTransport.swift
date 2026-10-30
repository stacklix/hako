import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

protocol ArcaneTerminalChannel: AnyObject, Sendable {
    func open() async throws
    func receive() async throws -> Data
    func send(_ data: Data) async throws
    func resize(columns: Int, rows: Int) async throws
    func close()
}

struct ArcaneTerminalClosed: LocalizedError {
    var errorDescription: String? { "终端会话已结束。" }
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
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                socket.sendPing { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
        } catch { throw mapped(error) }
    }
    func receive() async throws -> Data {
        do {
            switch try await socket.receive() {
            case .data(let data): return data
            case .string(let text): return Data(text.utf8)
            @unknown default: return Data()
            }
        } catch { throw mapped(error) }
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
                    token: String = UUID().uuidString.replacingOccurrences(of: "-", with: ""),
                    consume: @escaping @Sendable (Data) async -> Void) async throws -> Int {
        let script = try script(command, token: token)
        return try await withTaskCancellationHandler {
            defer { channel.close() }
            return try await withThrowingTaskGroup(of: Int.self) { group in
                group.addTask {
                    var sent = false
                    do {
                        try Task.checkCancellation()
                        try await channel.open()
                        try await channel.send(Data("PS1=; PS2=; stty -echo 2>/dev/null && printf '\\036\(token):ready\\037' || { printf '\\036\(token):setup-error\\037'; exit; }\n".utf8))
                        var decoder = ArcaneExecDecoder(token: token)
                        while !Task.isCancelled {
                            let event = try decoder.feed(try await channel.receive())
                            if event.becameReady {
                                // A failed send is uncertain too: the peer may have received it.
                                sent = true; try await channel.send(Data(script.utf8))
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
                defer { group.cancelAll() }
                return try await group.next()!
            }
        } onCancel: { channel.close() }
    }
}
