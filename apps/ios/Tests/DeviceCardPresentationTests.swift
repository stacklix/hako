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

        // Moving a page across the fifth position makes it a tab on reopening.
        let manifest = ["system", "codex", "ports", "http", "disk", "processes", "services"]
        let reordered = ["system", "codex", "ports", "http", "processes", "disk", "services"]
        let saved = DeviceCardOrder.saving(visible: reordered, previous: manifest)
        let restored = DeviceCardOrder.arranged(available: manifest, saved: saved)
        precondition(Array(restored.prefix(DeviceCardOrder.tabLimit)) == ["system", "codex", "ports", "http", "processes"])
        precondition(Array(restored.dropFirst(DeviceCardOrder.tabLimit)) == ["disk", "services"])
        print("PASS: device page order persistence, manifest changes, and the five-tab boundary")
    }
}
