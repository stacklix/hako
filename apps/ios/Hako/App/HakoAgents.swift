import Foundation

// Host API: children share the Agent registry and the single control socket.
// Support comes from the signed manifest, never from a module's live socket.
@MainActor enum HakoAgents {
    static let controlSocket = AgentRequestSocket(authentication: AuthenticatedServerService.shared, logSource: .devices)
    private static var catalog: [ConsoleAgent]?
    private static var catalogContext = ""
    struct Module: Decodable {
        let module: String
        let version: Int
        let path: String
    }
    static func list(refresh: Bool = false) async throws -> [ConsoleAgent] {
        let authentication = AuthenticatedServerService.shared
        guard authentication.authenticated, !authentication.logoutPending else { throw HakoError(message: "请先登录 Sora。") }
        let context = authentication.requestContext
        if catalogContext != context { catalog = nil; catalogContext = context }
        if refresh || catalog == nil {
            struct List: Decodable { let agents: [ConsoleAgent] }
            let data = try await controlSocket.send("list")
            guard context == authentication.requestContext else { throw CancellationError() }
            catalog = try JSONDecoder().decode(List.self, from: data).agents
        }
        return catalog ?? []
    }
    static func open(_ module: String, agentID: String) async throws -> Module {
        let agents = try await list()
        guard let agent = agents.first(where: { $0.id == agentID }), agent.online else { throw HakoError(message: "所选 Agent 当前离线。") }
        guard module == "workshop" && agent.supportsWorkshop || module == "proxy" && agent.supportsProxy else {
            throw HakoError(message: "所选 Agent 不支持此模块。")
        }
        let context = AuthenticatedServerService.shared.requestContext
        let data = try await controlSocket.send("module_open", agentID: agentID, body: ["module": module, "version": 1])
        guard context == AuthenticatedServerService.shared.requestContext else { throw CancellationError() }
        let ready: Module
        switch try JSONDecoder().decode(ConsoleAgentReply<Module>.self, from: data) {
        case .failure(let error): throw error
        case .result(let result): ready = result
        }
        let path = module == "proxy" ? "/ws/proxy/client/" + agentID : "/ws/workshop/client"
        guard ready.module == module, ready.version == 1, ready.path == path else { throw URLError(.badServerResponse) }
        return ready
    }
}
