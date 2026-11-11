import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@MainActor protocol AgentSocketConnection: AnyObject {
    var usable: Bool { get }
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receiveData() async throws -> Data
    func close()
}

extension URLSessionWebSocketTask: AgentSocketConnection {
    var usable: Bool { state == .running && closeCode == .invalid }
    func close() { cancel(with: .goingAway, reason: nil) }
}

struct AgentSocketFrame: Decodable {
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

@MainActor final class AgentRequestSocket {
    static let path = "/ws/console/agents"

    private let requestContext: () -> String
    private let openSocket: () async throws -> (any AgentSocketConnection, Data)
    private let requestTimeout: Duration
    private let idleTimeout: Duration
    private var context: String?
    private var generation = UUID()
    private var socket: (any AgentSocketConnection)?
    private var opening: Task<any AgentSocketConnection, Error>?
    private var reader: Task<Void, Never>?
    private var idle: Task<Void, Never>?
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]

    convenience init(authentication: any AuthenticatedServerAccess, logSource: HakoLogSource) {
        self.init(context: { authentication.requestContext }, open: {
            let (socket, hello) = try await authentication.openWebSocket(Self.path, logSource: logSource)
            return (socket, hello)
        })
    }

    init(context: @escaping () -> String, open: @escaping () async throws -> (any AgentSocketConnection, Data),
         requestTimeout: Duration = .seconds(15), idleTimeout: Duration = .seconds(45)) {
        requestContext = context; openSocket = open
        self.requestTimeout = requestTimeout; self.idleTimeout = idleTimeout
    }

    func resetIfContextChanged() {
        if context != requestContext() {
            disconnect(CancellationError())
            context = requestContext()
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
            try await Task.sleep(for: requestTimeout)
            guard pending[id] != nil else { return }
            if self.socket === socket { disconnect(URLError(.timedOut)) }
            else { finish(id, with: .failure(URLError(.timedOut))) }
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                Task {
                    guard pending[id] != nil else { return }
                    guard self.socket === socket else {
                        finish(id, with: .failure(URLError(.networkConnectionLost)))
                        return
                    }
                    do { try await socket.send(message) }
                    catch { if self.socket === socket { disconnect(error) } }
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish(id, with: .failure(CancellationError())) }
        }
    }

    private func connection() async throws -> any AgentSocketConnection {
        resetIfContextChanged()
        if let socket {
            if socket.usable { return socket }
            disconnect(URLError(.networkConnectionLost))
        }
        let generation = self.generation
        let task = opening ?? Task<any AgentSocketConnection, Error> {
            let (socket, hello) = try await openSocket()
            do {
                try Task.checkCancellation()
                try AgentSocketFrame.requireReady(hello)
                return socket
            } catch {
                socket.close()
                throw error
            }
        }
        opening = task
        do {
            let opened = try await task.value
            guard generation == self.generation, context == requestContext() else {
                opened.close()
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
                            let frame = try JSONDecoder().decode(AgentSocketFrame.self, from: data)
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
        let timeout = idleTimeout
        idle = Task { [weak self] in
            do { try await Task.sleep(for: timeout) }
            catch { return }
            self?.disconnect(CancellationError())
        }
    }

    private func disconnect(_ error: Error) {
        generation = UUID()
        idle?.cancel(); idle = nil
        opening?.cancel(); opening = nil
        reader?.cancel(); reader = nil
        socket?.close(); socket = nil
        let cancelled = pending
        pending.removeAll()
        for continuation in cancelled.values { continuation.resume(throwing: error) }
    }
}
