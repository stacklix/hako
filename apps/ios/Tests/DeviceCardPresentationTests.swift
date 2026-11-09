import Foundation

@main struct DeviceCardPresentationTests {
    static func main() throws {
        // Agent reconnects and manifest changes must not lose or duplicate commands.
        let available = ["query.a", "query.b", "query.new"]
        precondition(DeviceCardOrder.arranged(available: available, saved: ["query.b", "missing", "query.b", "query.a"])
                     == ["query.b", "query.a", "query.new"])
        let persisted = DeviceCardOrder.saving(visible: ["query.b", "query.a", "query.new"], previous: ["query.a", "missing", "query.b", "query.a"])
        precondition(persisted == ["query.b", "missing", "query.a", "query.new"])
        precondition(DeviceCardOrder.arranged(available: ["query.a", "missing", "query.b", "query.new"], saved: persisted) == persisted)
        let data = try JSONEncoder().encode(persisted)
        let decoded = try JSONDecoder().decode([String].self, from: data)
        precondition(decoded == persisted)
        let key = DeviceCardOrder.storageKey(server: "https://one.example", account: "owner", agent: "A1", group: "query")
        precondition(key != DeviceCardOrder.storageKey(server: "https://two.example", account: "owner", agent: "A1", group: "query"))
        precondition(key != DeviceCardOrder.storageKey(server: "https://one.example", account: "other", agent: "A1", group: "query"))
        precondition(key != DeviceCardOrder.storageKey(server: "https://one.example", account: "owner", agent: "B2", group: "query"))
        precondition(key != DeviceCardOrder.storageKey(server: "https://one.example", account: "owner", agent: "A1", group: "action"))

        let defaults = UserDefaults(suiteName: "hako-order-tests." + UUID().uuidString)!
        let actionKey = DeviceCardOrder.storageKey(server: "https://one.example", account: "owner", agent: "A1", group: "action")
        defaults.register(defaults: [
            key: try JSONEncoder().encode(["query.b", "query.a"]),
            actionKey: try JSONEncoder().encode(["action.c"])
        ])
        let order = DeviceCardOrder.Storage(server: "https://one.example", account: "owner", agent: "A1", defaults: defaults)
        let other = DeviceCardOrder.Storage(server: "https://one.example", account: "owner", agent: "B2", defaults: defaults)
        precondition(order.key == DeviceCardOrder.storageKey(server: "https://one.example", account: "owner", agent: "A1", group: "all"))
        precondition(DeviceCardOrder.names(from: order.initialData) == ["query.b", "query.a", "action.c"])
        precondition(order.key != other.key && DeviceCardOrder.names(from: other.initialData).isEmpty)

        // The terminal stays pinned. The first four movable pages get tabs.
        let manifest = ["system", "codex", "ports", "http", "disk", "processes", "services"]
        let reordered = ["system", "codex", "ports", "processes", "http", "disk", "services"]
        let saved = DeviceCardOrder.saving(visible: reordered, previous: manifest)
        let restored = DeviceCardOrder.arranged(available: manifest, saved: saved)
        precondition(Array(restored.prefix(DeviceCardOrder.visiblePageLimit)) == ["system", "codex", "ports", "processes"])
        precondition(Array(restored.dropFirst(DeviceCardOrder.visiblePageLimit)) == ["http", "disk", "services"])
        print("PASS: per-device page order, legacy order fallback, manifest changes, and the visible-page boundary")
    }
}
