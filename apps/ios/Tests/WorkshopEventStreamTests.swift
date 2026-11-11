import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Stub only the host authentication boundary; use the production stream reader.
enum HakoLogSource { case codeWorkshop }
struct ServerHTTPError: Error { let status: Int; let code: String }
@MainActor protocol AuthenticatedServerAccess: AnyObject {
    var requestContext: String { get }
    func openWebSocket(_ path: String, logSource: HakoLogSource) async throws -> (URLSessionWebSocketTask, Data)
}
@MainActor private final class PushSocket: WorkshopSocketConnection {
    var workshopUsable = true
    var reads = 0
    var sent = 0
    var queue: [Data] = []
    private var receiver: CheckedContinuation<Data, Error>?
    func sendWorkshop(_ message: URLSessionWebSocketTask.Message) async throws { sent += 1 }
    func receiveWorkshopData() async throws -> Data {
        reads += 1
        if !queue.isEmpty { return queue.removeFirst() }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }
    func closeWorkshop() {
        workshopUsable = false
        let old = receiver; receiver = nil
        old?.resume(throwing: CancellationError())
    }
}

@main @MainActor struct WorkshopEventStreamTests {
    struct Page: Decodable { let cursor: Int; let events: [String] }
    static let ready = Data(#"{"kind":"welcome","protocol":"hako.workshop/1"}"#.utf8)
    static func main() async throws {
        let pushed = PushSocket()
        pushed.queue = [
            Data(#"{"kind":"event","result":{"cursor":10,"events":["first"]}}"#.utf8),
            Data(#"{"kind":"event","result":{"cursor":20,"events":["second"]}}"#.utf8)
        ]
        var cursors: [Int] = []
        try await WorkshopEventStream.watch(open: { (pushed, ready) }) { (page: Page) in
            cursors.append(page.cursor)
            return cursors.count < 2
        }
        precondition(cursors == [10, 20] && pushed.sent == 0 && !pushed.workshopUsable,
                     "Push must render in order without sending poll requests, then release its socket")
        let quiet = PushSocket()
        let waiting = Task {
            try await WorkshopEventStream.watch(open: { (quiet, ready) }) { (_: Page) in true }
        }
        while quiet.reads == 0 { await Task.yield() }
        waiting.cancel()
        do { try await waiting.value; preconditionFailure("Cancellation must stop a quiet socket") }
        catch is CancellationError { }
        precondition(!quiet.workshopUsable, "Leaving after the grace period must close subscriptions")
        let failed = PushSocket()
        failed.queue = [Data(#"{"kind":"failure","error":{"code":"codex_operation_missing","message":"missing"}}"#.utf8)]
        do {
            try await WorkshopEventStream.watch(open: { (failed, ready) }) { (_: Page) in true }
            preconditionFailure("Agent failures must reach the reconnect loop")
        } catch let error as WorkshopFailure { precondition(error.code == "codex_operation_missing") }
        precondition(!failed.workshopUsable)
        print("PASS: unsolicited push delivery, ordered pages, quiet cancellation and failure cleanup")
    }
}
