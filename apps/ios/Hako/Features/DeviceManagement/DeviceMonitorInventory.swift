import Foundation

enum DeviceAgentHistory {
    static func agentID(in data: Data, scope: String) -> String? {
        (try? JSONDecoder().decode([String: String].self, from: data))?[scope]
    }
    static func remember(_ id: String?, scope: String, in data: Data) -> Data {
        var values = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        values[scope] = id
        return (try? JSONEncoder().encode(values)) ?? data
    }
}

struct DeviceMonitorInventory {
    enum ConnectionState: String {
        case unknown, online, offline
        var title: String {
            switch self {
            case .unknown: "待确认"
            case .online: "在线"
            case .offline: "离线"
            }
        }
    }
    var agents: [ConsoleAgent]
    private(set) var hasFetched = false
    private var connections: [String: ConnectionState] = [:]

    init(cachedAgents: [ConsoleAgent] = []) {
        agents = cachedAgents
        markUnknown()
    }

    mutating func receive(_ agents: [ConsoleAgent]) {
        self.agents = agents
        connections = Dictionary(agents.map { ($0.id, $0.online ? .online : .offline) }, uniquingKeysWith: { _, latest in latest })
        hasFetched = true
    }

    func connectionState(for id: String) -> ConnectionState {
        if agents.first(where: { $0.id == id })?.online == true { return .online }
        return connections[id] ?? .unknown
    }

    mutating func markUnknown() {
        markOffline()
        connections.removeAll()
    }

    mutating func markOffline(agentID: String? = nil) {
        agents = agents.map { agent in
            guard agentID == nil || agent.id == agentID else { return agent }
            connections[agent.id] = .offline
            return ConsoleAgent(dataQueryEnabled: agent.dataQueryEnabled, modules: agent.modules, id: agent.id, name: agent.name, online: false,
                                lastSeen: agent.lastSeen, capabilities: agent.capabilities)
        }
    }

    func selectedAgent(id: String?) -> ConsoleAgent? {
        guard let id else { return nil }
        if let agent = agents.first(where: { $0.id == id }) { return agent }
        // A failed request cannot establish that the selected device was removed.
        guard !hasFetched else { return nil }
        return ConsoleAgent(id: id, name: "设备", online: false, lastSeen: "", capabilities: nil)
    }

    struct Storage {
        let defaults: UserDefaults
        let key: String

        init(server: String, account: String, defaults: UserDefaults = .standard) {
            self.defaults = defaults
            let scope = try! JSONEncoder().encode([server, account])
            key = "hako.deviceMonitor.inventory." + scope.base64EncodedString()
        }

        func load() -> DeviceMonitorInventory {
            let agents = defaults.data(forKey: key).flatMap {
                try? JSONDecoder().decode([ConsoleAgent].self, from: $0)
            } ?? []
            return DeviceMonitorInventory(cachedAgents: agents)
        }

        func save(_ inventory: DeviceMonitorInventory) {
            guard let data = try? JSONEncoder().encode(inventory.agents) else { return }
            defaults.set(data, forKey: key)
        }
    }
}

enum DeviceMonitorFailure {
    static func message(for error: Error) -> String {
        guard let error = error as? URLError else { return error.localizedDescription }
        switch error.code {
        case .badURL, .unsupportedURL:
            return "设备管理连接地址无效，请检查服务器地址和网络后重试。"
        case .timedOut:
            return "连接服务器超时，暂时无法确认设备状态，请稍后重试。"
        default:
            return "无法连接服务器，暂时无法确认设备状态，请检查网络后重试。"
        }
    }
}
