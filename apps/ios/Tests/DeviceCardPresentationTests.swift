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

        // The terminal participates in the same saved order and tab/menu boundary.
        let manifest = ["system", "codex", "ports", "http", "disk", "processes", "services"]
        let terminal = DeviceCardOrder.terminalPageName
        let initialPages = DeviceCardOrder.pageNames(capabilities: manifest, saved: [])
        precondition(DeviceCardOrder.pageNames(capabilities: ["query.device.status", "query.telephony.sims"],
            saved: [terminal, "query.device.status"]) == ["query.device.status", "query.telephony.sims"],
            "Android must not inherit a terminal page from desktop defaults or saved order")
        precondition(initialPages == manifest + [terminal])
        precondition(DeviceCardOrder.pageNames(capabilities: [], saved: []) == [terminal],
                     "The terminal is a local page, independent of the Agent capability manifest")
        precondition(DeviceCardOrder.pageNames(capabilities: ["query.system.metrics", "action.network.http.check", "query.network.listeners"],
            saved: ["action.network.http.check", "query.network.listeners"]) == ["query.network.listeners", "query.system.metrics", terminal],
            "The removed URL connectivity page must stay absent from tabs, overflow and page ordering")
        let reordered = [terminal, "system", "codex", "ports", "processes", "http", "disk", "services"]
        let saved = DeviceCardOrder.saving(visible: reordered, previous: manifest)
        let restored = DeviceCardOrder.pageNames(capabilities: manifest, saved: saved)
        precondition(Array(restored.prefix(DeviceCardOrder.visiblePageLimit)) == [terminal, "system", "codex", "ports", "processes"])
        precondition(Array(restored.dropFirst(DeviceCardOrder.visiblePageLimit)) == ["http", "disk", "services"])
        let terminalInMenu = DeviceCardOrder.saving(visible: manifest + [terminal], previous: restored)
        let menuPages = DeviceCardOrder.pageNames(capabilities: manifest, saved: terminalInMenu)
        precondition(menuPages.dropFirst(DeviceCardOrder.visiblePageLimit).contains(terminal))
        precondition(DeviceCardOrder.pageNames(capabilities: manifest, saved: menuPages + [terminal]) == menuPages,
                     "Reopening settings must not duplicate the terminal")
        precondition(DeviceCardOrder.pageNames(capabilities: ["system"], saved: restored) == [terminal, "system"],
                     "Capability refreshes must preserve the terminal's saved position")
        print("PASS: per-device page order, terminal reordering, manifest changes, and the visible-page boundary")
    }
}
