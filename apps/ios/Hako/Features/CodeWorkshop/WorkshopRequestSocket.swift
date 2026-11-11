import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@MainActor protocol WorkshopSocketConnection: AnyObject {
    var workshopUsable: Bool { get }
    func sendWorkshop(_ message: URLSessionWebSocketTask.Message) async throws
    func receiveWorkshopData() async throws -> Data
    func closeWorkshop()
}
extension URLSessionWebSocketTask: WorkshopSocketConnection {
    var workshopUsable: Bool { state == .running && closeCode == .invalid }
    func sendWorkshop(_ message: URLSessionWebSocketTask.Message) async throws { try await send(message) }
    func receiveWorkshopData() async throws -> Data {
        switch try await receive() {
        case .data(let data): return data
        case .string(let text): return Data(text.utf8)
        @unknown default: throw CocoaError(.coderReadCorrupt)
        }
    }
    func closeWorkshop() { cancel(with: .goingAway, reason: nil) }
}
struct WorkshopSocketFrame: Decodable {
    let kind: String
    let `protocol`: String?
    let id: String?
    let result: WorkshopJSON?
    let error: WorkshopFailure?
    func resultData() throws -> Data {
        if let error { throw error }
        guard let result else { throw CocoaError(.coderReadCorrupt) }
        return try JSONEncoder().encode(result)
    }
    static func requireWelcome(_ data: Data) throws {
        let frame = try JSONDecoder().decode(Self.self, from: data)
        guard frame.kind == "welcome", frame.protocol == "hako.workshop/1" else { throw CocoaError(.coderReadCorrupt) }
    }
}



// Preserve integer values when presenting unknown query payloads.
enum WorkshopJSON: Codable {
    case object([String: WorkshopJSON]), array([WorkshopJSON]), string(String), integer(Int64), unsigned(UInt64), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int64.self) { self = .integer(v) }
        else if let v = try? c.decode(UInt64.self) { self = .unsigned(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: WorkshopJSON].self) { self = .object(v) }
        else { self = .array(try c.decode([WorkshopJSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .unsigned(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    func decode<T: Decodable>(_ type: T.Type) -> T? { (try? JSONEncoder().encode(self)).flatMap { try? JSONDecoder().decode(type, from: $0) } }
    var formatted: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "数据格式无效"
    }
}

@MainActor final class WorkshopRequestSocket {
    static let path = "/ws/workshop/client"

    private let requestContext: () -> String
    private let openSocket: () async throws -> (any WorkshopSocketConnection, Data)
    private let requestTimeout: Duration
    private let idleTimeout: Duration
    private var context: String?
    private var generation = UUID()
    private var socket: (any WorkshopSocketConnection)?
    private var opening: Task<any WorkshopSocketConnection, Error>?
    private var reader: Task<Void, Never>?
    private var idle: Task<Void, Never>?
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]

    convenience init(authentication: any AuthenticatedServerAccess, logSource: HakoLogSource) {
        self.init(context: { authentication.requestContext }, open: {
            let (socket, hello) = try await authentication.openWebSocket(Self.path, logSource: logSource)
            return (socket, hello)
        })
    }

    init(context: @escaping () -> String, open: @escaping () async throws -> (any WorkshopSocketConnection, Data),
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

    func close() { disconnect(CancellationError()); context = nil }

    func send(_ method: String, computerID: String? = nil, params: [String: Any] = [:]) async throws -> Data {
        let id = UUID().uuidString
        var frame: [String: Any] = ["id": id, "kind": "call", "method": method, "params": params]
        frame["computerId"] = computerID
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
                    do { try await socket.sendWorkshop(message) }
                    catch { if self.socket === socket { disconnect(error) } }
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish(id, with: .failure(CancellationError())) }
        }
    }

    private func connection() async throws -> any WorkshopSocketConnection {
        resetIfContextChanged()
        if let socket {
            if socket.workshopUsable { return socket }
            disconnect(URLError(.networkConnectionLost))
        }
        let generation = self.generation
        let task = opening ?? Task<any WorkshopSocketConnection, Error> {
            let (socket, hello) = try await openSocket()
            do {
                try Task.checkCancellation()
                try WorkshopSocketFrame.requireWelcome(hello)
                return socket
            } catch {
                socket.closeWorkshop()
                throw error
            }
        }
        opening = task
        do {
            let opened = try await task.value
            guard generation == self.generation, context == requestContext() else {
                opened.closeWorkshop()
                throw CancellationError()
            }
            if socket == nil {
                socket = opened
                opening = nil
                scheduleIdle()
                reader = Task { [weak self] in
                    do {
                        while !Task.isCancelled {
                            let data = try await opened.receiveWorkshopData()
                            guard let self, self.socket === opened else { return }
                            let frame = try JSONDecoder().decode(WorkshopSocketFrame.self, from: data)
                            guard (frame.kind == "result" || frame.kind == "failure"), let id = frame.id else { throw CocoaError(.coderReadCorrupt) }
                            if self.pending[id] != nil { self.finish(id, with: Result { try frame.resultData() }) }
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
        socket?.closeWorkshop(); socket = nil
        let cancelled = pending
        pending.removeAll()
        for continuation in cancelled.values { continuation.resume(throwing: error) }
    }
}
