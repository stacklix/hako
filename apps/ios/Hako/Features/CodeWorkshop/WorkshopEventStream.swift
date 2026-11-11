import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@MainActor enum WorkshopEventStream {
    static func watch<Value: Decodable>(
        open: () async throws -> (any AgentSocketConnection, Data),
        receive: (Value) async throws -> Bool
    ) async throws {
        let (socket, hello) = try await open()
        defer { socket.close() }
        try AgentSocketFrame.requireReady(hello)
        try await withTaskCancellationHandler {
            while true {
                try Task.checkCancellation()
                let frame = try JSONDecoder().decode(AgentSocketFrame.self, from: await socket.receiveData())
                if frame.type == "error" { _ = try frame.replyData(); throw CocoaError(.coderReadCorrupt) }
                guard frame.type == "update", let body = frame.body else { throw CocoaError(.coderReadCorrupt) }
                let reply = try JSONDecoder().decode(WorkshopReply<Value>.self, from: JSONEncoder().encode(body))
                if let failure = reply.error { throw failure }
                guard let value = reply.result else { throw CocoaError(.coderReadCorrupt) }
                let keepWatching = try await receive(value)
                if !keepWatching { return }
            }
        } onCancel: {
            Task { @MainActor in socket.close() }
        }
    }
}
