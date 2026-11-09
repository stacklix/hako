import Foundation

// Stored per server, account, device and command group. Missing commands retain their
// saved place; newly advertised commands are appended in the Agent's manifest order.
enum DeviceCardOrder {
    static let visiblePageLimit = 4

    struct Storage {
        let key: String
        let initialData: Data

        init(server: String, account: String, agent: String, defaults: UserDefaults = .standard) {
            key = DeviceCardOrder.storageKey(server: server, account: account, agent: agent, group: "all")
            let legacyNames = ["query", "action"].flatMap { group in
                let key = DeviceCardOrder.storageKey(server: server, account: account, agent: agent, group: group)
                return defaults.data(forKey: key).map(DeviceCardOrder.names) ?? []
            }
            initialData = (try? JSONEncoder().encode(legacyNames)) ?? Data()
        }
    }

    static func names(from data: Data) -> [String] {
        (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    static func arranged(available: [String], saved: [String]) -> [String] {
        let availableSet = Set(available)
        var seen = Set<String>()
        return (saved + available).filter { availableSet.contains($0) && seen.insert($0).inserted }
    }

    static func saving(visible: [String], previous: [String]) -> [String] {
        var seen = Set<String>()
        let unique = visible.filter { seen.insert($0).inserted }
        let active = Set(unique)
        var next = unique.makeIterator()
        seen.removeAll()
        var result = previous.filter { seen.insert($0).inserted }.compactMap { active.contains($0) ? next.next() : $0 }
        while let name = next.next() { result.append(name) }
        return result
    }

    static func storageKey(server: String, account: String, agent: String, group: String) -> String {
        let identity = (try? JSONEncoder().encode([server, account, agent, group])) ?? Data()
        return "hako.device-card-order." + identity.base64EncodedString()
    }
}
