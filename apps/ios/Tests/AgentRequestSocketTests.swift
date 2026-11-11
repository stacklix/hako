import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if AGENT_SOCKET_TESTS
// Only the app's authentication boundary is stubbed. The request multiplexer,
// deadlines, connection generations and receive loop are production code.
enum HakoLogSource { case codeWorkshop }
struct ServerHTTPError: Error { let status: Int; let code: String }
@MainActor protocol AuthenticatedServerAccess: AnyObject {
    var requestContext: String { get }
    func openWebSocket(_ path: String, logSource: HakoLogSource) async throws -> (URLSessionWebSocketTask, Data)
}
extension URLSessionWebSocketTask {
    func receiveData() async throws -> Data {
        switch try await receive() {
        case .data(let data): return data
        case .string(let string): return Data(string.utf8)
        @unknown default: throw CocoaError(.coderReadCorrupt)
        }
    }
}
#endif

@MainActor private final class TestConnection: AgentSocketConnection {
    var usable = true
    var replies = true
    var sent = 0
    private var queue: [Data] = []
    private var receiver: CheckedContinuation<Data, Error>?

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        sent += 1
        guard replies else { return }
        guard case .string(let text) = message,
              let frame = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let id = frame["id"] as? String else { preconditionFailure("Invalid outgoing frame") }
        let data = try JSONSerialization.data(withJSONObject: ["type": "reply", "id": id, "status": 200, "body": ["ok": true]])
        if let receiver { self.receiver = nil; receiver.resume(returning: data) }
        else { queue.append(data) }
    }

    func receiveData() async throws -> Data {
        if !queue.isEmpty { return queue.removeFirst() }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }

    func close() {
        usable = false
        let previous = receiver; receiver = nil
        previous?.resume(throwing: CancellationError())
    }
}

@main @MainActor struct AgentRequestSocketTests {
    static let ready = Data(#"{"type":"ready"}"#.utf8)

    static func main() async throws {
        let silent = TestConnection(); silent.replies = false
        let restored = TestConnection()
        var opens = 0
        let client = AgentRequestSocket(context: { "session" }, open: {
            opens += 1
            return (opens == 1 ? silent : restored, ready)
        }, requestTimeout: .milliseconds(100))
        do { _ = try await client.send("request"); preconditionFailure("Silent socket must time out") }
        catch let error as URLError { precondition(error.code == .timedOut) }
        precondition(!silent.usable && silent.sent == 1, "Timeout must close the dead connection without replaying a mutation")
        _ = try await client.send("request")
        precondition(opens == 2 && restored.sent == 1, "The next request must establish a fresh connection")

        let shared = TestConnection()
        var concurrentOpens = 0
        let multiplexed = AgentRequestSocket(context: { "session" }, open: {
            concurrentOpens += 1
            try await Task.sleep(for: .milliseconds(20))
            return (shared, ready)
        })
        let first = Task { try await multiplexed.send("list") }
        let second = Task { try await multiplexed.send("list") }
        _ = try await first.value; _ = try await second.value
        precondition(concurrentOpens == 1 && shared.sent == 2, "Concurrent recovery must share one opening connection")

        let cancelledConnection = TestConnection(); cancelledConnection.replies = false
        let nextSession = TestConnection()
        var context = "before"
        let contextual = AgentRequestSocket(context: { context }, open: {
            (context == "before" ? cancelledConnection : nextSession, ready)
        })
        let inFlight = Task { try await contextual.send("request") }
        while cancelledConnection.sent == 0 { await Task.yield() }
        context = "after"; contextual.resetIfContextChanged()
        do { _ = try await inFlight.value; preconditionFailure("Old-context request must be cancelled") }
        catch is CancellationError { precondition(!Task.isCancelled, "Connection cancellation is not cancellation of the observing task") }
        _ = try await contextual.send("list")
        precondition(nextSession.sent == 1 && !cancelledConnection.usable)

        let callerConnection = TestConnection(); callerConnection.replies = false
        let cancellable = AgentRequestSocket(context: { "session" }, open: { (callerConnection, ready) })
        let caller = Task { try await cancellable.send("list") }
        while callerConnection.sent == 0 { await Task.yield() }
        caller.cancel()
        do { _ = try await caller.value; preconditionFailure("Cancelled caller must finish") }
        catch is CancellationError { }
        callerConnection.replies = true
        _ = try await cancellable.send("list")
        precondition(callerConnection.usable, "Cancelling a view task must not break other callers")

        print("PASS: timed-out sockets close, next requests reconnect, shared opens, context cancellation, caller cancellation and no automatic action replay")
    }
}
