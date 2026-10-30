import Foundation
import Combine

@MainActor final class ECSTerminalData: ObservableObject {
    @Published private(set) var connecting = false
    @Published private(set) var connected = false
    @Published private(set) var cleaning = false
    @Published private(set) var error: String?
    @Published var control = false
    var receive: ((Data) -> Void)?
    var onReady: (() -> Void)?
    var keyInput: ((String) -> Void)?
    private var socket: URLSessionWebSocketTask?
    private var client: ECSClient?
    private var sessionID: String?
    private var reader: Task<Void, Never>?
    private var writer: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var flow = ECSAXTFlow()
    private var generation = UUID()
    private var queued = 0
    private var columns = 80
    private var rows = 24
    private var creating = false

    func connect(_ connection: ECSConnection) {
        guard !connecting, !connected, !cleaning else { return }
        HakoLog.record(.cloudServers, "开始连接终端")
        do {
            let client = try ECSClient(connection: connection)
            let ticket = UUID(); generation = ticket
            self.client = client; flow = ECSAXTFlow(); error = nil; connecting = true; creating = true
            // Do not cancel StartTerminalSession mid-flight: if the screen closes,
            // consume its late response and explicitly end the created session.
            reader = Task {
                var leased = false
                do {
                    let lease = try await client.startTerminal()
                    leased = true
                    creating = false
                    guard generation == ticket else { await end(client, id: lease.id); cleaning = false; return }
                    sessionID = lease.id
                    let socket = client.session.webSocketTask(with: lease.url)
                    socket.maximumMessageSize = 1_048_576
                    self.socket = socket; socket.resume()
                    deadline = Task {
                        try? await Task.sleep(for: .seconds(25))
                        guard !Task.isCancelled, generation == ticket, !connected else { return }
                        error = "等待云助手终端就绪超时。"; disconnect()
                        HakoLog.record(.cloudServers, .error, "等待终端就绪超时")
                    }
                    while generation == ticket {
                        let message = try await socket.receive()
                        let bytes: Data
                        switch message {
                        case .data(let value): bytes = value
                        case .string: throw ECSFailure(message: "终端返回了非预期的文本消息。")
                        @unknown default: throw ECSFailure(message: "终端返回了无法识别的消息。")
                        }
                        guard generation == ticket else { return }
                        let event = try flow.receive(ECSAXTFrame.decode(bytes))
                        for frame in event.replies { try enqueue(frame) }
                        if event.ready && !connected {
                            onReady?()
                            connected = true; connecting = false; deadline?.cancel(); deadline = nil
                            HakoLog.record(.cloudServers, "终端已连接")
                            resize(columns: columns, rows: rows)
                            heartbeat = Task {
                                while !Task.isCancelled {
                                    do { try await Task.sleep(for: .seconds(45)); try Task.checkCancellation() } catch { return }
                                    guard generation == ticket, connected else { return }
                                    do { try enqueue(flow.message(type: 0)) } catch { fail(error) }
                                }
                            }
                        }
                        if !event.bytes.isEmpty { receive?(event.bytes) }
                        if event.ended { disconnect(); return }
                    }
                } catch {
                    if !leased {
                        creating = false
                        if generation != ticket { cleaning = false }
                    }
                    if generation == ticket { fail(error) }
                }
            }
        } catch { self.error = error.localizedDescription }
    }
    func send(_ bytes: Data) {
        guard connected else { return }
        var data = bytes
        if control, data.count == 1, let byte = data.first, (64...127).contains(byte) { data = Data([byte & 0x1f]); control = false }
        do {
            guard data.count <= 1_048_576 else { throw ECSFailure(message: "单次粘贴不能超过 1 MB。") }
            for offset in stride(from: 0, to: data.count, by: 1024) {
                try enqueue(flow.message(type: 0, payload: data.subdata(in: offset..<min(offset + 1024, data.count))))
            }
        } catch { fail(error) }
    }
    func resize(columns: Int, rows: Int) {
        self.columns = max(2, min(1000, columns)); self.rows = max(2, min(1000, rows))
        guard connected else { return }
        do { try enqueue(flow.message(type: 2, payload: ECSAXTFlow.size(columns: columns, rows: rows))) }
        catch { fail(error) }
    }
    private func enqueue(_ frame: ECSAXTFrame) throws {
        guard let socket else { return }
        let payload = try frame.encode()
        guard queued + payload.count <= 1_200_000 else { throw ECSFailure(message: "终端发送队列已满，请重新连接。") }
        queued += payload.count
        let previous = writer, ticket = generation
        writer = Task {
            await previous?.value
            guard !Task.isCancelled, generation == ticket else { return }
            defer { if generation == ticket { queued -= payload.count } }
            do { try await socket.send(.data(payload)) }
            catch { if generation == ticket { fail(error) } }
        }
    }
    private func fail(_ failure: Error) {
        error = (failure as? ECSFailure)?.message ?? "终端连接已断开，请检查网络及云助手状态。"
        HakoLog.record(.cloudServers, .error, "终端连接失败", detail: error ?? "")
        disconnect()
    }
    func disconnect() {
        if connecting || connected { HakoLog.record(.cloudServers, "终端已断开") }
        if creating { cleaning = true }
        generation = UUID()
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        // The in-flight creation task intentionally remains alive for cleanup.
        reader = nil; writer?.cancel(); writer = nil; queued = 0
        heartbeat?.cancel(); heartbeat = nil; deadline?.cancel(); deadline = nil
        connected = false; connecting = false; control = false
        if let client, let id = sessionID {
            cleaning = true
            Task { await end(client, id: id); cleaning = false }
        }
        sessionID = nil; client = nil
    }
    private func end(_ client: ECSClient, id: String) async {
        do { try await client.endTerminal(id) }
        catch {
            self.error = "本机已断开，云端会话清理失败；请在阿里云控制台核对会话。"
            HakoLog.record(.cloudServers, .warning, "云端终端会话清理失败")
        }
    }
}
