import Foundation

@MainActor enum WorkshopLocalSocket {
    private static let session = HTTPTransport.makeSession(requestTimeout: 8)

    static func open(_ endpoint: LocalNetworkEndpoint, path: String) async throws -> (any WorkshopSocketConnection, Data) {
        guard endpoint.isValid, let url = endpoint.url(scheme: "ws", path: path) else { throw CocoaError(.coderReadCorrupt) }
        let socket = session.webSocketTask(with: url)
        socket.resume()
        var timedOut = false
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            timedOut = true
            socket.closeWorkshop()
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                let hello = try await socket.receiveWorkshopData()
                try Task.checkCancellation()
                try WorkshopSocketFrame.requireWelcome(hello)
                return (socket, hello)
            } catch { socket.closeWorkshop(); if timedOut { throw URLError(.timedOut) }; throw error }
        } onCancel: { socket.cancel(with: .goingAway, reason: nil) }
    }
}
