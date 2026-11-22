import Foundation

@MainActor enum HakoHTTPProxyClient {
    private static var context = ""
    private static var connections: [String: AgentRequestSocket] = [:]

    static func send(agentID: String, parameters: [String: Any]) async throws -> Data {
        let authentication = AuthenticatedServerService.shared
        let ticket = authentication.requestContext
        if context != ticket {
            connections.values.forEach { $0.close() }; connections = [:]; context = ticket
        }
        let socket: AgentRequestSocket
        if let existing = connections[agentID] { socket = existing }
        else {
            socket = AgentRequestSocket(context: { authentication.requestContext }, open: {
                let ready = try await HakoAgents.open("proxy", agentID: agentID)
                guard ticket == authentication.requestContext else { throw CancellationError() }
                let (connection, hello) = try await authentication.openWebSocket(ready.path, logSource: .hako)
                connection.maximumMessageSize = 12 * 1024 * 1024
                return (connection, hello)
            })
            connections[agentID] = socket
        }
        let reply = try await socket.send("request", body: ["version": 1, "request": parameters])
        guard ticket == authentication.requestContext else { throw CancellationError() }
        return reply
    }
}
