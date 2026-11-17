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
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let packet):
            let size = packet.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            precondition(packet.count > 4 + size)
            data = packet.subdata(in: 4..<(4 + size))
        @unknown default: preconditionFailure()
        }
        guard let frame = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { preconditionFailure() }
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
        try await checkEventBatches(welcome: welcome)
        let imageID = "11111111-1111-4111-8111-111111111111"
        let image = Data(repeating: 123, count: 200_000)
        var initializations = 0, activeChunks = 0, maximumInFlight = 0
        var received: Set<Int> = [0]
        var positions: [Int] = [], progressValues: [Double] = []
        func prefix() -> Int {
            var position = 0
            while position < image.count && received.contains(position) { position += min(32 * 1024, image.count - position) }
            return position
        }
        try await WorkshopImageTransfer.upload(id: imageID, data: image, initialize: {
            initializations += 1
            return WorkshopUpload(id: imageID, nextOffset: prefix(), complete: prefix() == image.count)
        }, send: { packet in
            precondition(String(data: packet.prefix(36), encoding: .utf8) == imageID && packet.count <= 32 * 1024 + 40)
            let position = packet[36..<40].reduce(0) { ($0 << 8) | Int($1) }
            positions.append(position); activeChunks += 1; maximumInFlight = max(maximumInFlight, activeChunks)
            defer { activeChunks -= 1 }
            try await Task.sleep(for: .milliseconds(5))
            precondition(packet.dropFirst(40) == image.subdata(in: position..<min(position + 32 * 1024, image.count)))
            received.insert(position)
            return try JSONSerialization.data(withJSONObject: ["id": imageID, "nextOffset": prefix(), "complete": prefix() == image.count])
        }, progress: { progressValues.append($0) })
        precondition(initializations == 2 && maximumInFlight == 4 && activeChunks == 0,
            "The real upload loop must send a bounded window before waiting for every acknowledgement")
        precondition(!positions.contains(0) && prefix() == image.count, "Resume must skip acknowledged image bytes")
        precondition(progressValues.last == 1 && zip(progressValues, progressValues.dropFirst()).allSatisfy { $0 <= $1 }, "Progress must follow acknowledged contiguous bytes and never go backwards")
        var cancellationActive = 0
        let cancelledUpload = Task {
            try await WorkshopImageTransfer.upload(id: imageID, data: image, initialize: {
                WorkshopUpload(id: imageID, nextOffset: 0, complete: false)
            }, send: { _ in
                cancellationActive += 1; defer { cancellationActive -= 1 }
                try await Task.sleep(for: .seconds(10))
                throw URLError(.timedOut)
            }, progress: { _ in })
        }
        while cancellationActive < 4 { await Task.yield() }
        cancelledUpload.cancel()
        do { try await cancelledUpload.value; preconditionFailure("Upload cancellation did not propagate") } catch { }
        precondition(cancellationActive == 0, "Cancellation must drain every in-flight binary chunk")
        let binaryTransport = WorkshopTestSocket()
        let binaryClient = WorkshopRequestSocket(context: { "account" }, open: { (binaryTransport, welcome) })
        let binaryCall = Task { try await binaryClient.sendBinary(Data([0, 255, 2]), computerID: "PC") }
        while binaryTransport.sent.isEmpty { await Task.yield() }
        precondition(binaryTransport.sent[0]["computerId"] as? String == "PC")
        try binaryTransport.push(["kind":"result", "id":binaryTransport.sent[0]["id"]!, "result":["nextOffset":3]])
        _ = try await binaryCall.value
        binaryClient.close()
        let fairTransport = WorkshopTestSocket()
        let fair = WorkshopRequestSocket(context: { "account" }, open: { (fairTransport, welcome) })
        let images = (0..<4).map { _ in Task { try await fair.sendBinary(Data([0, 1, 2]), computerID: "PC") } }
        while fairTransport.sent.count < 4 { await Task.yield() }
        let fifth = Task { try await fair.sendBinary(Data([0, 1, 2]), computerID: "PC") }
        let sixth = Task { try await fair.sendBinary(Data([0, 1, 2]), computerID: "PC") }
        let ordinary = Task { try await fair.send("models.list", computerID: "PC") }
        while fairTransport.sent.count < 5 { await Task.yield() }
        precondition(fairTransport.sent.filter { $0["method"] == nil }.count == 4,
            "All conversations together must share the four-chunk budget, leaving room for ordinary requests")
        sixth.cancel(); _ = try? await sixth.value
        for frame in fairTransport.sent {
            try fairTransport.push(["kind":"result", "id":frame["id"]!, "result":["ok":true]])
        }
        while fairTransport.sent.count < 6 { await Task.yield() }
        try fairTransport.push(["kind":"result", "id":fairTransport.sent[5]["id"]!, "result":["ok":true]])
        for image in images { _ = try await image.value }
        _ = try await fifth.value
        _ = try await ordinary.value
        fair.close()
        print("PASS: binary upload window, resume offsets, raw JPEG bytes, monotonic progress and draining cancellation")
        print("PASS: shared calls/streams, per-view cancellation, timeout isolation, foreground lifetime and reconnect cursors")
        print("PASS: Workshop-only handshake, independent call schema, multiplexing and out-of-order reply identity")
    }

    static func checkEventBatches(welcome: Data) async throws {
        let transport = WorkshopTestSocket()
        let client = WorkshopRequestSocket(context: { "account" }, open: { (transport, welcome) })
        var batches: [[Int]] = []
        let watcher = Task {
            try await client.watchBatches(computerID: "PC", operationID: "op", cursor: 0, interval: .seconds(60)) { batch in
                batches.append(try batch.map { data in
                    let value = try JSONSerialization.jsonObject(with: data) as! [String: Int]
                    return value["cursor"]!
                })
                return false
            }
        }
        while transport.sent.isEmpty { await Task.yield() }
        let id = transport.sent[0]["id"]!
        for cursor in 1...32 { try transport.push(["kind": "event", "id": id, "result": ["cursor": cursor]]) }
        try await watcher.value
        precondition(batches == [Array(1...32)], "A burst must publish once at the batch limit without reordering or dropping events")

        var quietDeliveries = 0
        let quiet = Task {
            try await client.watchBatches(computerID: "PC", operationID: "quiet", cursor: 0, interval: .milliseconds(5)) { batch in
                quietDeliveries += batch.count; return false
            }
        }
        while !transport.sent.contains(where: { $0["operationId"] as? String == "quiet" }) { await Task.yield() }
        let quietID = transport.sent.first { $0["operationId"] as? String == "quiet" }!["id"]!
        try transport.push(["kind": "event", "id": quietID, "result": ["cursor": 1]])
        try await quiet.value
        precondition(quietDeliveries == 1, "A single event must flush without waiting for another event")

        var cancelledDeliveries = 0
        let cancelled = Task {
            try await client.watchBatches(computerID: "PC", operationID: "cancelled", cursor: 0, interval: .seconds(60)) { _ in
                cancelledDeliveries += 1; return true
            }
        }
        while !transport.sent.contains(where: { $0["operationId"] as? String == "cancelled" }) { await Task.yield() }
        let cancelledID = transport.sent.first { $0["operationId"] as? String == "cancelled" }!["id"]!
        try transport.push(["kind": "event", "id": cancelledID, "result": ["cursor": 1]])
        while !transport.queued.isEmpty || transport.receiver == nil { await Task.yield() }
        cancelled.cancel(); _ = try? await cancelled.value
        precondition(cancelledDeliveries == 0 && transport.workshopUsable, "Cancelling a pending batch must preserve the shared socket and prevent late delivery")

        var release: CheckedContinuation<Void, Never>?
        let overloaded = Task {
            try await client.watchBatches(computerID: "PC", operationID: "overloaded", cursor: 0, interval: .seconds(60)) { _ in
                if release == nil { await withCheckedContinuation { release = $0 } }
                return true
            }
        }
        while !transport.sent.contains(where: { $0["operationId"] as? String == "overloaded" }) { await Task.yield() }
        let overloadedID = transport.sent.first { $0["operationId"] as? String == "overloaded" }!["id"]!
        for cursor in 1...32 { try transport.push(["kind": "event", "id": overloadedID, "result": ["cursor": cursor]]) }
        while release == nil { await Task.yield() }
        for cursor in 33...96 { try transport.push(["kind": "event", "id": overloadedID, "result": ["cursor": cursor]]) }
        while !transport.queued.isEmpty || transport.receiver == nil { await Task.yield() }
        release!.resume()
        do { try await overloaded.value; preconditionFailure("A stalled consumer must recover instead of silently losing events") }
        catch { precondition((error as? URLError)?.code == .dataLengthExceedsMaximum) }
        precondition(transport.workshopUsable, "One overflowing subscription must not interrupt other conversations")
        client.close()

        func payload(_ cursor: Int, _ text: String, state: String = "running", approvals: [[String: Any]] = []) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["operation": ["id": "op", "applicationId": "app", "state": state, "startedAt": 1],
                "events": [["kind": "delta", "id": "reply", "text": text, "role": "assistant", "state": "", "truncated": false]],
                "cursor": cursor, "hasMore": state == "running", "approvals": approvals, "artifacts": [], "followups": []])
        }
        let pages = try await WorkshopSocketDecoder.shared.operationPages([
            payload(1, "你"), payload(2, "好 👋"), payload(2, "DUPLICATE"),
            payload(3, "确认", state: "waiting", approvals: [["id": "approval", "kind": "command", "detail": "run", "questions": []]]),
            payload(4, "完成", state: "completed")], operationID: "op", after: 0)
        precondition(pages.count == 3 && pages.map(\.cursor) == [2, 3, 4])
        precondition(pages[0].events.map(\.text) == ["你", "好 👋"] && pages[0].hasMore)
        precondition(pages[1].approvals.first?.id == "approval" && pages[2].operation.state == "completed" && !pages[2].hasMore,
            "Batching must retain approval and terminal boundaries with their own cursor")
        do {
            _ = try await WorkshopSocketDecoder.shared.operationPages([payload(1, "old")], operationID: "op", after: 2)
            preconditionFailure("A regressing cursor must trigger recovery")
        } catch { }
        do {
            _ = try await WorkshopSocketDecoder.shared.operationPages([payload(1, "wrong operation")], operationID: "other", after: 0)
            preconditionFailure("A mismatched operation must not publish")
        } catch { }
        let largeInteger = try await WorkshopSocketDecoder.shared.frame(Data(#"{"kind":"result","id":"integer","result":{"cursor":9223372036854775807}}"#.utf8))
        let value = try JSONSerialization.jsonObject(with: largeInteger.result.get()) as! [String: NSNumber]
        precondition(value["cursor"]?.int64Value == Int64.max, "Background decoding must preserve exact integer cursors")
        print("PASS: bounded event batches, timed delivery, cancellation, overflow recovery, Unicode, duplicate cursors, approval/terminal boundaries and integer precision")
    }
}
