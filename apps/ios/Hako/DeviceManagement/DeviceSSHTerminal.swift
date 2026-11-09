import Foundation
import Combine

struct DeviceSSHCredentials: Codable {
    var username = ""
    var password = ""
    var fingerprint = ""

    var isValid: Bool {
        guard (1...256).contains(username.utf8.count),
              !username.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              (1...4096).contains(password.utf8.count),
              fingerprint.hasPrefix("SHA256:"),
              let hash = Data(base64Encoded: String(fingerprint.dropFirst(7)) + "="), hash.count == 32 else { return false }
        return fingerprint == "SHA256:" + hash.base64EncodedString().dropLast()
    }
}

@MainActor final class DeviceSSHTerminal: HakoNativeTerminalData {
    @Published private(set) var connected = false
    @Published private(set) var connecting = false
    @Published private(set) var message: String?
    @Published var control = false
    let display = ECSTerminalDisplay()
    private var socket: URLSessionWebSocketTask?
    private var reader: Task<Void, Never>?
    private var writer: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var messages: AsyncStream<URLSessionWebSocketTask.Message>.Continuation?
    private var generation = UUID()
    private var columns = 80
    private var rows = 24

    func connect(agentID: String, credentials: DeviceSSHCredentials, authentication: any AuthenticatedServerAccess) {
        guard !connecting, !connected, credentials.isValid,
              agentID.range(of: #"\A[A-Za-z0-9_-]{1,80}\z"#, options: .regularExpression) != nil else { return }
        let ticket = UUID()
        generation = ticket
        let context = authentication.requestContext
        display.beginSession()
        message = nil
        connecting = true
        deadline = Task {
            do { try await Task.sleep(for: .seconds(25)) } catch { return }
            if generation == ticket { end("SSH 连接超时。") }
        }
        reader = Task {
            do {
                let (socket, hello) = try await authentication.openWebSocket("/ws/console/agents/terminal/" + agentID, logSource: .devices)
                defer { socket.cancel(with: .goingAway, reason: nil) }
                guard generation == ticket, authentication.requestContext == context else { return }
                self.socket = socket
                let greeting = String(decoding: hello, as: UTF8.self)
                guard greeting == "ssh_login" else { end(Self.status(greeting)); return }
                let login: [String: Any] = [
                    "username": credentials.username, "password": credentials.password,
                    "fingerprint": credentials.fingerprint, "columns": columns, "rows": rows,
                ]
                try await socket.send(try Self.json(login))
                while !Task.isCancelled, generation == ticket {
                    let event = try await socket.receive()
                    guard !Task.isCancelled, generation == ticket, authentication.requestContext == context else { return }
                    switch event {
                    case .string("ssh_ready") where connecting:
                        beginWriting(socket, ticket: ticket)
                        deadline?.cancel()
                        connecting = false
                        connected = true
                        resize(columns: columns, rows: rows)
                    case .data(let bytes) where connected && bytes.count <= 4096:
                        display.append(bytes)
                    case .string(let status):
                        end(Self.status(status)); return
                    default:
                        end("SSH 终端返回了无效消息。"); return
                    }
                }
            } catch {
                guard !Task.isCancelled, generation == ticket else { return }
                end((error as? ServerHTTPError)?.status == 404
                    ? "Hako 服务端暂不支持 SSH 终端，请先更新服务端。"
                    : "SSH 终端连接已断开。")
            }
        }
    }

    func send(_ bytes: Data) {
        guard connected else { return }
        var data = bytes
        if control, data.count == 1, let byte = data.first, (64...127).contains(byte) {
            data = Data([byte & 0x1f])
            control = false
        }
        guard data.count <= 131_072 else { message = "单次粘贴最多 128 KB。"; return }
        for offset in stride(from: 0, to: data.count, by: 4096) {
            enqueue(.data(data.subdata(in: offset..<min(offset + 4096, data.count))))
        }
    }

    func resize(columns: Int, rows: Int) {
        self.columns = max(2, min(1000, columns))
        self.rows = max(2, min(1000, rows))
        if connected, let frame = try? Self.json(["columns": self.columns, "rows": self.rows]) { enqueue(frame) }
    }

    func disconnect() { end(nil) }

    private func beginWriting(_ socket: URLSessionWebSocketTask, ticket: UUID) {
        let (stream, continuation) = AsyncStream<URLSessionWebSocketTask.Message>.makeStream(bufferingPolicy: .bufferingOldest(64))
        messages = continuation
        writer = Task {
            do {
                for await frame in stream { try await socket.send(frame) }
            } catch {
                if !Task.isCancelled, generation == ticket { end("SSH 输入发送失败，请重新连接。") }
            }
        }
    }

    private func enqueue(_ frame: URLSessionWebSocketTask.Message) {
        if case .dropped? = messages?.yield(frame) { end("SSH 输入过快，请重新连接。") }
    }

    private func end(_ message: String?) {
        generation = UUID()
        deadline?.cancel(); deadline = nil
        reader?.cancel(); reader = nil
        writer?.cancel(); writer = nil
        messages?.finish(); messages = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        display.blur()
        control = false
        connecting = false
        connected = false
        self.message = message
    }

    private static func json(_ value: [String: Any]) throws -> URLSessionWebSocketTask.Message {
        .string(String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self))
    }

    private static func status(_ code: String) -> String {
        switch code {
        case "agent_offline": return "设备离线，请先连接 Windows Agent。"
        case "ssh_unsupported": return "设备 Agent 暂不支持 SSH 转发，请更新 Windows Agent。"
        case "ssh_busy": return "该设备已有打开的终端，请关闭后重试。"
        case "ssh_unavailable": return "无法连接 Windows OpenSSH，请检查 sshd 是否在本机端口 22 监听。"
        case "ssh_host_key_mismatch": return "SSH 主机指纹不匹配，连接已中止。"
        case "ssh_invalid_login": return "SSH 登录信息无效，请检查设置。"
        case "ssh_failed": return "无法启动 PowerShell，请检查 SSH 登录信息和 Windows OpenSSH 配置。"
        case "ssh_ended": return "PowerShell 会话已结束。"
        default: return "SSH 终端返回了无效消息。"
        }
    }
}
