import Foundation

struct HakoError: Error { let message: String }
enum HakoLogSource { case devices }
@MainActor final class FakeAuthentication {
    var authenticated = true, logoutPending = false
    var requestContext = "session-A"
}
@MainActor enum AuthenticatedServerService { static let shared = FakeAuthentication() }
@MainActor final class AgentRequestSocket {
    static var agents: [ConsoleAgent] = []
    static var fetches = 0
    static var openings: [(String, String)] = []
    static var responsePath: String?
    init(authentication: FakeAuthentication, logSource: HakoLogSource) { }
    func send(_ type: String, agentID: String? = nil, body: [String: Any]? = nil) async throws -> Data {
        if type == "list" {
            Self.fetches += 1
            struct List: Encodable { let agents: [ConsoleAgent] }
            return try JSONEncoder().encode(List(agents: Self.agents))
        }
        precondition(type == "module_open" && body?["version"] as? Int == 1)
        let module = body!["module"] as! String, id = agentID!
        Self.openings.append((module, id))
        return try JSONSerialization.data(withJSONObject: ["result": ["module": module, "version": 1,
            "path": Self.responsePath ?? (module == "proxy" ? "/ws/proxy/client/" + id : "/ws/workshop/client")]])
    }
}

@main struct HakoAgentsTests {
    @MainActor static func main() async throws {
        let client = AgentRequestSocket.self
        let service = ConsoleAgentModules.Service(version: 1, lan: nil)
        client.agents = [
            .init(modules: .init(workshop: service, proxy: nil), id: "WORK", name: "Workshop", online: true, lastSeen: "", capabilities: []),
            .init(modules: .init(workshop: nil, proxy: service), id: "PROXY", name: "Proxy", online: true, lastSeen: "", capabilities: []),
            .init(modules: .init(workshop: service, proxy: service), id: "OFF", name: "Offline", online: false, lastSeen: "", capabilities: [])
        ]
        let all = try await HakoAgents.list()
        precondition(all.count == 3 && client.fetches == 1)
        precondition(all.filter(\.supportsWorkshop).map(\.id) == ["WORK", "OFF"])
        precondition(all.filter(\.supportsProxy).map(\.id) == ["PROXY", "OFF"])
        _ = try await HakoAgents.list()
        precondition(client.fetches == 1)
        _ = try await HakoAgents.open("workshop", agentID: "WORK")
        _ = try await HakoAgents.open("proxy", agentID: "PROXY")
        precondition(client.openings.count == 2 && client.openings[0].1 == "WORK" && client.openings[1].1 == "PROXY")
        do { _ = try await HakoAgents.open("proxy", agentID: "WORK"); preconditionFailure("Unsupported module was opened") } catch { }
        do { _ = try await HakoAgents.open("proxy", agentID: "OFF"); preconditionFailure("Offline module was opened") } catch { }
        precondition(client.openings.count == 2)
        client.responsePath = "https://untrusted.invalid/ws"
        do { _ = try await HakoAgents.open("proxy", agentID: "PROXY"); preconditionFailure("Untrusted module destination accepted") } catch { }
        AuthenticatedServerService.shared.logoutPending = true
        do { _ = try await HakoAgents.list(); preconditionFailure("Logged-out catalog returned") } catch { }
        print("PASS: one shared catalog, independent child filters/selections, declared support while offline, module readiness and destination validation.")
    }
}
