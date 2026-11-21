import Foundation

@main struct AndroidVideoShutdownTests {
    @MainActor static func main() async throws {
        var actions = 0, queries = 0
        func success() async throws { actions += 1 }
        func timeout() async throws { actions += 1; throw URLError(.timedOut) }
        func state(_ value: String) async throws -> String { queries += 1; return value }
        let acknowledged = try await AndroidVideoShutdown.finish(stop: success, screen: { try await state("on") })
        precondition(acknowledged == nil && actions == 1 && queries == 0)
        for value in ["off", "doze"] {
            let recovered = try await AndroidVideoShutdown.finish(stop: timeout, screen: { try await state(value) })
            precondition(recovered == nil)
        }
        let awake = try await AndroidVideoShutdown.finish(stop: timeout, screen: { try await state("on") })
        precondition(awake?.contains("手机仍亮屏") == true)
        let unknown = try await AndroidVideoShutdown.finish(stop: timeout, screen: { try await state("unknown") })
        precondition(unknown?.contains("暂时无法确认") == true)
        let disconnected = try await AndroidVideoShutdown.finish(stop: timeout, screen: { queries += 1; throw URLError(.networkConnectionLost) })
        precondition(disconnected == unknown && actions == 6 && queries == 5)
        do {
            _ = try await AndroidVideoShutdown.finish(stop: { throw CancellationError() }, screen: { try await state("on") })
            preconditionFailure("Cancelled shutdown should not query another device context")
        } catch is CancellationError { }
        precondition(queries == 5)
        print("PASS: stop acknowledgement, timeout reconciliation, sleep/doze/awake/unknown, no action replay and cancellation.")
    }
}
