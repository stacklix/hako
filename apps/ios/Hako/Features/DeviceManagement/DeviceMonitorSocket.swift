import Foundation

struct DeviceMonitorFrame: Decodable {
    let type: String
    let id: String?
    let status: Int?
    let body: ConsoleJSON?

    func replyData() throws -> Data {
        guard let status, let body else { throw CocoaError(.coderReadCorrupt) }
        let data = try JSONEncoder().encode(body)
        if !(200..<300).contains(status) {
            struct Failure: Decodable { let error: String }
            throw ServerHTTPError(status: status, code: (try? JSONDecoder().decode(Failure.self, from: data).error) ?? "invalid_response")
        }
        return data
    }

    static func requireReady(_ data: Data) throws {
        guard try JSONDecoder().decode(Self.self, from: data).type == "ready" else {
            throw CocoaError(.coderReadCorrupt)
        }
    }
}

@MainActor final class DeviceMonitorSocket {
    static let path = "/ws/console/agents"

    private let authentication: any AuthenticatedServerAccess
    private var context: String?
    private var generation = UUID()
    private var socket: URLSessionWebSocketTask?
    private var opening: Task<URLSessionWebSocketTask, Error>?
    private var reader: Task<Void, Never>?
    private var idle: Task<Void, Never>?
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]

    init(authentication: any AuthenticatedServerAccess) { self.authentication = authentication }

    func resetIfContextChanged() {
        if context != authentication.requestContext {
            disconnect(CancellationError())
            context = authentication.requestContext
        }
    }

    func send(_ type: String, agentID: String? = nil, body: [String: Any]? = nil) async throws -> Data {
        let id = UUID().uuidString
        var frame: [String: Any] = ["id": id, "type": type]
        frame["agentId"] = agentID
        frame["body"] = body
        let message = URLSessionWebSocketTask.Message.string(String(decoding: try JSONSerialization.data(withJSONObject: frame), as: UTF8.self))
        let socket = try await connection()
        try Task.checkCancellation()
        idle?.cancel()
        let deadline = Task {
            try await Task.sleep(for: .seconds(15))
            finish(id, with: .failure(HakoError(message: "设备请求超时，请先确认结果。")))
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                Task {
                    guard pending[id] != nil, self.socket === socket else { return }
                    do { try await socket.send(message) }
                    catch { if self.socket === socket { disconnect(error) } }
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish(id, with: .failure(CancellationError())) }
        }
    }

    private func connection() async throws -> URLSessionWebSocketTask {
        resetIfContextChanged()
        if let socket { return socket }
        let generation = self.generation
        let task = opening ?? Task {
            let (socket, hello) = try await authentication.openWebSocket(Self.path, logSource: .devices)
            do {
                try Task.checkCancellation()
                try DeviceMonitorFrame.requireReady(hello)
                return socket
            } catch {
                socket.cancel(with: .goingAway, reason: nil)
                throw error
            }
        }
        opening = task
        do {
            let opened = try await task.value
            guard generation == self.generation, context == authentication.requestContext else {
                opened.cancel(with: .goingAway, reason: nil)
                throw CancellationError()
            }
            if socket == nil {
                socket = opened
                opening = nil
                scheduleIdle()
                reader = Task { [weak self] in
                    do {
                        while !Task.isCancelled {
                            let data = try await opened.receiveData()
                            guard let self, self.socket === opened else { return }
                            let frame = try JSONDecoder().decode(DeviceMonitorFrame.self, from: data)
                            guard frame.type == "reply", let id = frame.id else { throw CocoaError(.coderReadCorrupt) }
                            if self.pending[id] != nil { self.finish(id, with: Result { try frame.replyData() }) }
                        }
                    } catch {
                        if let self, self.socket === opened { self.disconnect(error) }
                    }
                }
            }
            return opened
        } catch {
            if generation == self.generation { disconnect(error) }
            throw error
        }
    }

    private func finish(_ id: String, with result: Result<Data, Error>) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(with: result)
        if pending.isEmpty { scheduleIdle() }
    }

    private func scheduleIdle() {
        idle?.cancel()
        idle = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(45)) }
            catch { return }
            self?.disconnect(CancellationError())
        }
    }

    private func disconnect(_ error: Error) {
        generation = UUID()
        idle?.cancel(); idle = nil
        opening?.cancel(); opening = nil
        reader?.cancel(); reader = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        let cancelled = pending
        pending.removeAll()
        for continuation in cancelled.values { continuation.resume(throwing: error) }
    }
}
