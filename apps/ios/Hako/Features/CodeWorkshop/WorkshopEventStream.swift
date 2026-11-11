import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@MainActor enum WorkshopEventStream {
    static func watch<Value: Decodable>(
        open: () async throws -> (any WorkshopSocketConnection, Data),
        receive: (Value) async throws -> Bool
    ) async throws {
        let (socket, hello) = try await open()
        defer { socket.closeWorkshop() }
        try WorkshopSocketFrame.requireWelcome(hello)
        try await withTaskCancellationHandler {
            while true {
                try Task.checkCancellation()
                let frame = try JSONDecoder().decode(WorkshopSocketFrame.self, from: await socket.receiveWorkshopData())
                if let failure = frame.error { throw failure }
                guard frame.kind == "event" else { throw CocoaError(.coderReadCorrupt) }
                let value = try JSONDecoder().decode(Value.self, from: frame.resultData())
                let keepWatching = try await receive(value)
                if !keepWatching { return }
            }
        } onCancel: {
            Task { @MainActor in socket.closeWorkshop() }
        }
    }
}
