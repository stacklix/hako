import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@MainActor protocol WorkshopSocketConnection: AnyObject, Sendable {
    var workshopUsable: Bool { get }
    var workshopCloseCode: Int? { get }
    func sendWorkshop(_ message: URLSessionWebSocketTask.Message) async throws
    func receiveWorkshopData() async throws -> Data
    func closeWorkshop()
}
extension WorkshopSocketConnection { var workshopCloseCode: Int? { nil } }
extension URLSessionWebSocketTask: WorkshopSocketConnection {
    var workshopUsable: Bool { state == .running && closeCode == .invalid }
    var workshopCloseCode: Int? { closeCode == .invalid ? nil : closeCode.rawValue }
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

enum WorkshopSocketDiagnostics {
    // Error descriptions/userInfo may include URLs, headers and server payloads.
    static func error(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let failure = error as? WorkshopFailure {
            let known: Set<String> = ["query_timeout", "process_unavailable", "process_disconnected", "computer_offline",
                "workshop_timeout", "workshop_busy", "workshop_disconnected", "codex_connection_closed", "stream_overflow",
                "invalid_request", "unsupported_method"]
            return "workshop/" + (known.contains(failure.code) ? failure.code : "other")
        }
        let value = error as NSError
        let known = [NSURLErrorDomain, NSPOSIXErrorDomain, NSCocoaErrorDomain]
        return "\(known.contains(value.domain) ? value.domain : "other")/\(value.code)"
    }
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

struct WorkshopDecodedSocketFrame: Sendable {
    let kind: String
    let id: String?
    let result: Result<Data, Error>
}

// Decode and unwrap payloads away from the UI actor. Only routing and publishing
// the prepared values belong on MainActor, including when the socket is local.
actor WorkshopSocketDecoder {
    static let shared = WorkshopSocketDecoder()

    func frame(_ data: Data) throws -> WorkshopDecodedSocketFrame {
        try Task.checkCancellation()
        let frame = try JSONDecoder().decode(WorkshopSocketFrame.self, from: data)
        return WorkshopDecodedSocketFrame(kind: frame.kind, id: frame.id, result: Result { try frame.resultData() })
    }

    func operationPages(_ payloads: [Data], operationID: String, after initialCursor: Int64) throws -> [WorkshopOperationPage] {
        var pages: [WorkshopOperationPage] = []
        var cursor = initialCursor
        for data in payloads {
            try Task.checkCancellation()
            let page = try JSONDecoder().decode(WorkshopOperationPage.self, from: data)
            guard page.operation.id == operationID, page.cursor >= cursor else { throw CocoaError(.coderReadCorrupt) }
            // A metadata-only frame may repeat the cursor. Never apply its
            // events twice, even when it shares a batch with a newer page.
            let events = page.cursor > cursor ? page.events : []
            if let previous = pages.last, previous.operation == page.operation,
               previous.approvals == page.approvals, previous.artifacts == page.artifacts,
               previous.followups == page.followups {
                pages[pages.count - 1] = WorkshopOperationPage(operation: page.operation, events: previous.events + events,
                    cursor: page.cursor, hasMore: page.hasMore, approvals: page.approvals,
                    artifacts: page.artifacts, followups: page.followups)
            } else {
                pages.append(WorkshopOperationPage(operation: page.operation, events: events, cursor: page.cursor,
                    hasMore: page.hasMore, approvals: page.approvals, artifacts: page.artifacts, followups: page.followups))
            }
            cursor = page.cursor
        }
        return pages
    }
}

// A bounded, lossless batch: overflow fails the subscription so its caller can
// recover from the last applied cursor instead of silently skipping deltas.
@MainActor private final class WorkshopSocketSubscription {
    private let continuation: AsyncThrowingStream<[Data], Error>.Continuation
    private let interval: Duration
    private var buffered: [Data] = []
    private var bufferedBytes = 0
    private var timer: Task<Void, Never>?
    private var finished = false

    init(_ continuation: AsyncThrowingStream<[Data], Error>.Continuation, interval: Duration) {
        self.continuation = continuation; self.interval = interval
    }

    func yield(_ data: Data) {
        guard !finished else { return }
        buffered.append(data)
        bufferedBytes += data.count
        if interval == .zero || buffered.count >= 32 || bufferedBytes >= 256 * 1024 { flush(); return }
        guard timer == nil else { return }
        let delay = interval
        timer = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            self?.flush()
        }
    }

    private func flush() {
        timer?.cancel(); timer = nil
        guard !finished, !buffered.isEmpty else { return }
        let batch = buffered; buffered.removeAll(keepingCapacity: true)
        bufferedBytes = 0
        switch continuation.yield(batch) {
        case .dropped: finish(URLError(.dataLengthExceedsMaximum))
        case .terminated: finish()
        case .enqueued: break
        @unknown default: finish(URLError(.badServerResponse))
        }
    }

    func finish(_ error: Error? = nil) {
        guard !finished else { return }
        finished = true
        timer?.cancel(); timer = nil; buffered.removeAll(); bufferedBytes = 0
        continuation.finish(throwing: error)
    }
}

@MainActor final class WorkshopRequestSocket {
    static let path = "/ws/workshop/client"
    var onDisconnect: (() -> Void)?
    var onFailure: ((Error) -> Void)?
    private var persistent = false
    private var binaryActive = 0
    private var binaryWaiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []
    private var streams: [String: WorkshopSocketSubscription] = [:]

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
    private var requestStarted: [String: Date] = [:]
    private var silentRequests: Set<String> = []
    private var connectedAt: Date?
    private var recoveryStarted: Date?
    var onDiagnostic: ((String, String) -> Void)?
    private let diagnosticSink: (String, String) -> Void
    private func diagnostic(_ event: String, _ detail: String) {
        diagnosticSink(event, detail)
        onDiagnostic?(event, detail)
    }

    convenience init(authentication: any AuthenticatedServerAccess, logSource: HakoLogSource) {
        self.init(context: { authentication.requestContext }, open: {
            let (socket, hello) = try await authentication.openWebSocket(Self.path, logSource: logSource)
            return (socket, hello)
        }, diagnostic: { event, detail in
            HakoLog.record(logSource, event.contains("failed") || event == "disconnected" ? .warning : .info,
                           "会话连接：\(event)", detail: detail)
        })
    }

    init(context: @escaping () -> String, open: @escaping () async throws -> (any WorkshopSocketConnection, Data),
         requestTimeout: Duration = .seconds(15), idleTimeout: Duration = .seconds(45),
         diagnostic: @escaping (String, String) -> Void = { _, _ in }) {
        requestContext = context; openSocket = open
        self.requestTimeout = requestTimeout; self.idleTimeout = idleTimeout
        self.diagnosticSink = diagnostic
    }

    func resetIfContextChanged() {
        if context != requestContext() {
            disconnect(CancellationError())
            context = requestContext()
        }
    }

    func close() { disconnect(CancellationError()); context = nil }

    func setPersistent(_ value: Bool) {
        persistent = value
        if value { idle?.cancel(); idle = nil }
        else { close() }
    }

    func watch(computerID: String, operationID: String, cursor: Int64,
               receive: (Data) async throws -> Bool) async throws {
        try await watchBatches(computerID: computerID, operationID: operationID, cursor: cursor, interval: .zero) { batch in
            for data in batch {
                if try await receive(data) == false { return false }
            }
            return true
        }
    }

    func watchBatches(computerID: String, operationID: String, cursor: Int64, interval: Duration = .milliseconds(40),
                      receive: ([Data]) async throws -> Bool) async throws {
        let id = UUID().uuidString
        let socket = try await connection()
        try Task.checkCancellation()
        idle?.cancel()
        let stream = AsyncThrowingStream<[Data], Error>(bufferingPolicy: .bufferingOldest(interval == .zero ? 32 : 1)) {
            streams[id] = WorkshopSocketSubscription($0, interval: interval)
        }
        defer {
            streams.removeValue(forKey: id)?.finish()
            if self.socket === socket {
                Task { [weak self] in
                    // A queued cancellation must never reach a replacement connection.
                    guard let self, self.socket === socket else { return }
                    try? await socket.sendWorkshop(.string("{\"kind\":\"unwatch\",\"id\":\"\(id)\"}"))
                }
            }
            if pending.isEmpty && streams.isEmpty { scheduleIdle() }
        }
        let frame: [String: Any] = ["kind": "watch", "id": id, "computerId": computerID,
                                    "operationId": operationID, "cursor": cursor]
        do {
            try await socket.sendWorkshop(.string(String(decoding: JSONSerialization.data(withJSONObject: frame), as: UTF8.self)))
        } catch {
            if self.socket === socket { disconnect(error) }
            throw error
        }
        for try await data in stream {
            try Task.checkCancellation()
            if try await receive(data) == false { return }
        }
    }

    func send(_ method: String, computerID: String? = nil, params: [String: Any] = [:]) async throws -> Data {
        // Uploads and downloads share a small transfer budget, leaving request
        // slots available for messages, approvals and state reconciliation.
        let transfer = method == "image.read" || method == "artifact.read"
        if transfer { try await acquireBinarySlot() }
        defer { if transfer { releaseBinarySlot() } }
        let id = UUID().uuidString
        var frame: [String: Any] = ["id": id, "kind": "call", "method": method, "params": params]
        frame["computerId"] = computerID
        let message = URLSessionWebSocketTask.Message.string(String(decoding: try JSONSerialization.data(withJSONObject: frame), as: UTF8.self))
        return try await perform(message, id: id, reportFailure: method != "diagnostics.append")
    }

    func sendBinary(_ payload: Data, computerID: String) async throws -> Data {
        guard payload.count <= 32 * 1024 + 40 else { throw URLError(.dataLengthExceedsMaximum) }
        resetIfContextChanged()
        let generation = self.generation
        try await acquireBinarySlot()
        defer { releaseBinarySlot() }
        try Task.checkCancellation()
        guard generation == self.generation else { throw CancellationError() }
        let id = UUID().uuidString
        let header = try JSONSerialization.data(withJSONObject: ["id": id, "computerId": computerID])
        var length = UInt32(header.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(header); frame.append(payload)
        return try await perform(.data(frame), id: id)
    }

    private func acquireBinarySlot() async throws {
        try Task.checkCancellation()
        if binaryActive < 4 { binaryActive += 1; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                binaryWaiters.append((id, continuation))
            }
        } onCancel: {
            Task { @MainActor in
                if let index = self.binaryWaiters.firstIndex(where: { $0.id == id }) {
                    self.binaryWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
                }
            }
        }
    }

    private func releaseBinarySlot() {
        if binaryWaiters.isEmpty { binaryActive -= 1 }
        else { binaryWaiters.removeFirst().continuation.resume() }
    }

    private func perform(_ message: URLSessionWebSocketTask.Message, id: String, reportFailure: Bool = true) async throws -> Data {
        let socket = try await connection()
        try Task.checkCancellation()
        idle?.cancel()
        let deadline = Task {
            try await Task.sleep(for: requestTimeout)
            guard pending[id] != nil else { return }
            finish(id, with: .failure(URLError(.timedOut)))
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                requestStarted[id] = .now
                if !reportFailure { silentRequests.insert(id) }
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
                connectedAt = .now
                diagnostic("connected", "connection=\(generation); downtimeMs=\(recoveryStarted.map { Int(Date.now.timeIntervalSince($0) * 1000) } ?? 0)")
                recoveryStarted = nil
                opening = nil
                scheduleIdle()
                reader = Task { [weak self] in
                    do {
                        while !Task.isCancelled {
                            let data = try await opened.receiveWorkshopData()
                            let frame = try await WorkshopSocketDecoder.shared.frame(data)
                            try Task.checkCancellation()
                            guard let self, self.socket === opened else { return }
                            guard ["result", "failure", "event", "unwatched"].contains(frame.kind), let id = frame.id else { throw CocoaError(.coderReadCorrupt) }
                            if let stream = self.streams[id] {
                                if frame.kind == "failure" {
                                    self.streams[id] = nil
                                    switch frame.result {
                                    case .failure(let error):
                                        self.diagnostic("subscription_failed", "connection=\(self.generation); subscription=\(id); error=\(WorkshopSocketDiagnostics.error(error))")
                                        stream.finish(error)
                                    case .success: stream.finish(URLError(.badServerResponse))
                                    }
                                } else if frame.kind == "event" {
                                    stream.yield(try frame.result.get())
                                }
                            } else if self.pending[id] != nil {
                                self.finish(id, with: frame.result)
                            }
                        }
                    } catch {
                        if let self, self.socket === opened { self.disconnect(error) }
                    }
                }
            }
            return opened
        } catch {
            if generation == self.generation {
                diagnostic("connection_failed", "connection=\(generation); error=\(WorkshopSocketDiagnostics.error(error))")
                if !(error is CancellationError) { recoveryStarted = recoveryStarted ?? .now }
                disconnect(error)
            }
            throw error
        }
    }

    private func finish(_ id: String, with result: Result<Data, Error>) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        let started = requestStarted.removeValue(forKey: id)
        let silent = silentRequests.remove(id) != nil
        if case .failure(let error) = result, !(error is CancellationError), !silent {
            diagnostic("request_failed", "connection=\(generation); request=\(id); elapsedMs=\(started.map { Int(Date.now.timeIntervalSince($0) * 1000) } ?? 0); error=\(WorkshopSocketDiagnostics.error(error))")
        }
        continuation.resume(with: result)
        if pending.isEmpty && streams.isEmpty { scheduleIdle() }
    }

    private func scheduleIdle() {
        idle?.cancel()
        guard !persistent, streams.isEmpty, pending.isEmpty else { return }
        let timeout = idleTimeout
        idle = Task { [weak self] in
            do { try await Task.sleep(for: timeout) }
            catch { return }
            self?.disconnect(CancellationError())
        }
    }

    private func disconnect(_ error: Error) {
        if socket != nil || opening != nil {
            let expected = error is CancellationError || (error as NSError).code == NSURLErrorCancelled
            diagnostic(expected ? "closed" : "disconnected", "connection=\(generation); error=\(WorkshopSocketDiagnostics.error(error)); closeCode=\(socket?.workshopCloseCode ?? 0); uptimeMs=\(connectedAt.map { Int(Date.now.timeIntervalSince($0) * 1000) } ?? 0); pending=\(pending.count); subscriptions=\(streams.count)")
            if !expected { recoveryStarted = recoveryStarted ?? .now }
        }
        connectedAt = nil
        requestStarted.removeAll()
        silentRequests.removeAll()
        generation = UUID()
        idle?.cancel(); idle = nil
        opening?.cancel(); opening = nil
        reader?.cancel(); reader = nil
        socket?.closeWorkshop(); socket = nil
        let waiting = binaryWaiters; binaryWaiters.removeAll()
        for entry in waiting { entry.continuation.resume(throwing: error) }
        let subscriptions = streams; streams.removeAll()
        for stream in subscriptions.values { stream.finish(error) }
        let cancelled = pending
        pending.removeAll()
        for continuation in cancelled.values { continuation.resume(throwing: error) }
        // Explicit close, route changes and idle retirement do not mean a
        // previously verified computer went offline.
        if !(error is CancellationError) { onFailure?(error); onDisconnect?() }
    }
}

@MainActor enum WorkshopDownloadTransfer {
    static let chunkSize = 24 * 1024
    static let window = 4

    static func read(id: String, maximum: Int, cached: (Data, String)? = nil,
                     fetch: @escaping (Int, String?) async throws -> WorkshopArtifactChunk) async throws -> (Data, String) {
        let first = try await fetch(0, nil)
        guard first.id == id, first.offset == 0, first.total >= 0, first.total <= maximum,
              first.revision.count == 64 else { throw CocoaError(.coderReadCorrupt) }
        let revision = first.revision
        func bytes(_ chunk: WorkshopArtifactChunk, at offset: Int) throws -> Data {
            guard chunk.id == id, chunk.offset == offset, chunk.total == first.total, chunk.revision == revision,
                  let data = Data(base64Encoded: chunk.content), data.count == min(chunkSize, first.total - offset),
                  chunk.nextOffset == offset + data.count else { throw CocoaError(.coderReadCorrupt) }
            return data
        }
        var data = try bytes(first, at: 0)
        if let cached, cached.1 == revision, cached.0.count == first.total { return cached }
        data.reserveCapacity(first.total)
        while data.count < first.total {
            try Task.checkCancellation()
            let start = data.count
            let offsets = Array(stride(from: start, to: min(first.total, start + window * chunkSize), by: chunkSize))
            let tasks = offsets.map { offset in Task { try await fetch(offset, revision) } }
            do {
                try await withTaskCancellationHandler {
                    for (offset, task) in zip(offsets, tasks) {
                        let chunk = try await task.value
                        try Task.checkCancellation()
                        data.append(try bytes(chunk, at: offset))
                    }
                } onCancel: { for task in tasks { task.cancel() } }
            } catch {
                for task in tasks { task.cancel() }
                for task in tasks { _ = try? await task.value }
                throw error
            }
        }
        return (data, revision)
    }
}

@MainActor enum WorkshopImageTransfer {
    static let chunkSize = 32 * 1024
    static let window = 4
    static func upload(id: String, data: Data, initialize: () async throws -> WorkshopUpload,
                       send: @escaping (Data) async throws -> Data, progress: (Double) -> Void) async throws {
        guard data.count > 0, data.count <= 2_000_000, id.utf8.count == 36 else { throw CocoaError(.coderReadCorrupt) }
        let begin = try await initialize()
        guard begin.id == id, (0...data.count).contains(begin.nextOffset),
              begin.nextOffset == data.count || begin.nextOffset % chunkSize == 0,
              !begin.complete || begin.nextOffset == data.count else { throw CocoaError(.coderReadCorrupt) }
        var offset = begin.nextOffset
        var confirmed = offset
        progress(Double(confirmed) / Double(data.count))
        while offset < data.count {
            try Task.checkCancellation()
            var transfers: [Task<WorkshopUpload, Error>] = []
            let batchEnd = min(data.count, offset + window * chunkSize)
            for start in stride(from: offset, to: batchEnd, by: chunkSize) {
                var packet = Data(id.utf8)
                var position = UInt32(start).bigEndian
                packet.append(withUnsafeBytes(of: &position) { Data($0) })
                packet.append(data.subdata(in: start..<min(start + chunkSize, data.count)))
                let payload = packet
                transfers.append(Task {
                    let reply = try await send(payload)
                    return try JSONDecoder().decode(WorkshopUpload.self, from: reply)
                })
            }
            let batch = transfers
            do {
                try await withTaskCancellationHandler {
                    for transfer in batch {
                        let reply = try await transfer.value
                        try Task.checkCancellation()
                        guard reply.id == id, (0...data.count).contains(reply.nextOffset),
                              reply.nextOffset == data.count || reply.nextOffset % chunkSize == 0 else { throw CocoaError(.coderReadCorrupt) }
                        confirmed = max(confirmed, reply.nextOffset)
                        progress(Double(confirmed) / Double(data.count))
                    }
                } onCancel: { for transfer in batch { transfer.cancel() } }
            } catch {
                for transfer in batch { transfer.cancel() }
                for transfer in batch { _ = try? await transfer.value }
                throw error
            }
            offset = batchEnd
        }
        let verified = try await initialize()
        guard verified.id == id, verified.complete, verified.nextOffset == data.count else { throw CocoaError(.coderReadCorrupt) }
        progress(1)
    }
}
