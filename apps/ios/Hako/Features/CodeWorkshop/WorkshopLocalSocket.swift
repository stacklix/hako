import Foundation

@MainActor enum WorkshopLocalSocket {
    // A literal LAN endpoint must not be sent through a system HTTP/PAC proxy.
    private static let session = HTTPTransport.makeSession(requestTimeout: 8, useSystemProxy: false)

    static func open(_ endpoint: LocalNetworkEndpoint, path: String, commandToken: String? = nil) async throws -> (any WorkshopSocketConnection, Data) {
        guard endpoint.isValid, let url = endpoint.url(scheme: "ws", path: path) else { throw CocoaError(.coderReadCorrupt) }
        var request = URLRequest(url: url)
        if let commandToken { request.setValue(commandToken, forHTTPHeaderField: "X-Hako-Command") }
        let socket = session.webSocketTask(with: request)
        let started = ContinuousClock.now
        var stage = "welcome"
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
                stage = "protocol"
                try WorkshopSocketFrame.requireWelcome(hello)
                HakoLog.record(.codeWorkshop, "局域网连接握手成功", detail: "route=direct; proxy=disabled")
                return (socket, hello)
            } catch {
                socket.closeWorkshop()
                let failure: Error = timedOut ? URLError(.timedOut) : error
                let elapsed = started.duration(to: .now).components
                let milliseconds = elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000
                let response = (socket.response as? HTTPURLResponse).map { String($0.statusCode) } ?? "none"
                let underlying = (failure as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
                HakoLog.record(.codeWorkshop, Task.isCancelled ? .warning : .error, "局域网连接握手失败",
                    detail: "stage=\(stage); route=direct; proxy=disabled; elapsedMs=\(milliseconds); http=\(response); error=\(WorkshopSocketDiagnostics.error(failure)); underlying=\(underlying.map { WorkshopSocketDiagnostics.error($0) } ?? "none")")
                throw failure
            }
        } onCancel: { socket.cancel(with: .goingAway, reason: nil) }
    }
}
