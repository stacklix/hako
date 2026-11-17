import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum HakoLogSource { case codeWorkshop }
@MainActor protocol AuthenticatedServerAccess: AnyObject {
    var requestContext: String { get }
    func openWebSocket(_ path: String, logSource: HakoLogSource) async throws -> (URLSessionWebSocketTask, Data)
}

@MainActor private final class WorkshopTestSocket: WorkshopSocketConnection {
    var workshopUsable = true
    var sent: [[String: Any]] = []
    var queued: [Data] = []
    var receiver: CheckedContinuation<Data, Error>?
    func sendWorkshop(_ message: URLSessionWebSocketTask.Message) async throws {
        guard case .string(let text) = message,
              let frame = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { preconditionFailure() }
        sent.append(frame)
    }
    func receiveWorkshopData() async throws -> Data {
        if !queued.isEmpty { return queued.removeFirst() }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }
    func push(_ frame: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: frame)
        if let old = receiver { receiver = nil; old.resume(returning: data) } else { queued.append(data) }
    }
    func closeWorkshop() {
        workshopUsable = false
        let old = receiver; receiver = nil
        old?.resume(throwing: CancellationError())
    }
}

@main @MainActor struct WorkshopRequestSocketTests {
    static func main() async throws {
        let welcome = Data(#"{"kind":"welcome","protocol":"hako.workshop/1"}"#.utf8)
        do { try WorkshopSocketFrame.requireWelcome(Data(#"{"type":"ready"}"#.utf8)); preconditionFailure("Device handshake accepted by Workshop") }
        catch { }
        let transport = WorkshopTestSocket()
        var opens = 0
        let client = WorkshopRequestSocket(context: { "workshop-account" }, open: { opens += 1; return (transport, welcome) })
        var disconnects = 0
        client.onDisconnect = { disconnects += 1 }
        let first = Task { try await client.send("history.read", computerID: "PC", params: ["threadId": "thread"]) }
        while transport.sent.count < 1 { await Task.yield() }
        let second = Task { try await client.send("models.list", computerID: "PC") }
        while transport.sent.count < 2 { await Task.yield() }
        precondition(opens == 1)
        for frame in transport.sent {
            precondition(frame["kind"] as? String == "call" && frame["computerId"] as? String == "PC")
            precondition(frame["type"] == nil && frame["body"] == nil && frame["version"] == nil)
        }
        try transport.push(["kind": "result", "id": transport.sent[1]["id"]!, "result": ["answer": 2]])
        try transport.push(["kind": "result", "id": transport.sent[0]["id"]!, "result": ["answer": 1]])
        let firstValue = try await first.value
        let secondValue = try await second.value
        let firstReply = try JSONSerialization.jsonObject(with: firstValue) as? [String: Int]
        let secondReply = try JSONSerialization.jsonObject(with: secondValue) as? [String: Int]
        precondition(firstReply == ["answer": 1] && secondReply == ["answer": 2])
        client.close()
        precondition(!transport.workshopUsable)
        precondition(disconnects == 0, "Leaving or retiring an idle socket must not claim the computer is offline")
        let broken = WorkshopTestSocket()
        let brokenClient = WorkshopRequestSocket(context: { "workshop-account" }, open: { (broken, welcome) })
        brokenClient.onDisconnect = { disconnects += 1 }
        let request = Task { try await brokenClient.send("history.read", computerID: "PC") }
        while broken.sent.isEmpty { await Task.yield() }
        while broken.receiver == nil { await Task.yield() }
        let receiver = broken.receiver; broken.receiver = nil
        receiver?.resume(throwing: URLError(.networkConnectionLost))
        do { _ = try await request.value; preconditionFailure("Broken transport unexpectedly replied") }
        catch { }
        precondition(disconnects == 1, "A reader failure must immediately update connection presentation")
        let multiplex = WorkshopTestSocket()
        var sharedOpens = 0
        let shared = WorkshopRequestSocket(context: { "account" }, open: { sharedOpens += 1; return (multiplex, welcome) },
            requestTimeout: .milliseconds(30), idleTimeout: .milliseconds(10))
        shared.setPersistent(true)
        var eventsA = 0, eventsB = 0
        let streamA = Task { try await shared.watch(computerID: "PC", operationID: "operation-a", cursor: 7) { _ in eventsA += 1; return true } }
        while multiplex.sent.count < 1 { await Task.yield() }
        let streamB = Task { try await shared.watch(computerID: "PC", operationID: "operation-b", cursor: 9) { _ in eventsB += 1; return true } }
        while multiplex.sent.count < 2 { await Task.yield() }
        let idA = multiplex.sent[0]["id"]!, idB = multiplex.sent[1]["id"]!
        precondition(multiplex.sent[0]["cursor"] as? Int64 == 7 && multiplex.sent[1]["cursor"] as? Int64 == 9)
        try multiplex.push(["kind":"event", "id": idB, "result":["cursor":10]])
        while eventsB == 0 { await Task.yield() }
        precondition(eventsA == 0 && sharedOpens == 1, "Streams must route by subscription ID on one socket")
        let timedOut = Task { try await shared.send("history.read", computerID: "PC") }
        do { _ = try await timedOut.value; preconditionFailure("Expected a single request timeout") } catch { }
        precondition(multiplex.workshopUsable && sharedOpens == 1, "A slow request must not disconnect other conversations")
        streamA.cancel(); _ = try? await streamA.value
        while !multiplex.sent.contains(where: { $0["kind"] as? String == "unwatch" && $0["id"] as? String == idA as? String }) { await Task.yield() }
        try multiplex.push(["kind":"event", "id": idA, "result":["cursor":8]])
        try multiplex.push(["kind":"event", "id": idB, "result":["cursor":11]])
        while eventsB < 2 { await Task.yield() }
        precondition(eventsA == 0 && sharedOpens == 1, "Cancelling one view must preserve the other stream and shared connection")
        streamB.cancel(); _ = try? await streamB.value
        try await Task.sleep(for: .milliseconds(25))
        precondition(multiplex.workshopUsable, "Foreground connection must survive its old idle deadline")
        shared.setPersistent(false)
        precondition(!multiplex.workshopUsable, "Background transition must release the foreground connection")
        let resumed = WorkshopTestSocket()
        var current = resumed
        let reconnecting = WorkshopRequestSocket(context: { "account" }, open: { (current, welcome) })
        let interrupted = Task { try await reconnecting.watch(computerID: "PC", operationID: "same-operation", cursor: 11) { _ in true } }
        while resumed.receiver == nil || resumed.sent.isEmpty { await Task.yield() }
        let waiting = resumed.receiver; resumed.receiver = nil
        waiting?.resume(throwing: URLError(.networkConnectionLost))
        do { try await interrupted.value; preconditionFailure("Lost connection did not end subscription") } catch { }
        current = WorkshopTestSocket()
        let replacement = current
        let restarted = Task { try await reconnecting.watch(computerID: "PC", operationID: "same-operation", cursor: 12) { _ in false } }
        while replacement.sent.isEmpty { await Task.yield() }
        precondition(replacement.sent[0]["cursor"] as? Int64 == 12, "Reconnection must preserve the caller's updated resume cursor")
        try replacement.push(["kind":"event", "id":replacement.sent[0]["id"]!, "result":["cursor":13]])
        try await restarted.value
        reconnecting.close()
        print("PASS: shared calls/streams, per-view cancellation, timeout isolation, foreground lifetime and reconnect cursors")
        print("PASS: Workshop-only handshake, independent call schema, multiplexing and out-of-order reply identity")
    }
}
