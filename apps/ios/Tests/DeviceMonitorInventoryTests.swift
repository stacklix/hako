import Foundation

@main struct DeviceMonitorInventoryTests {
    static func main() throws {
        var history = Data()
        let alice = "https://one.example\nalice", bob = "https://one.example\nbob"
        precondition(DeviceAgentHistory.agentID(in: history, scope: alice) == nil)
        history = DeviceAgentHistory.remember("A1234", scope: alice, in: history)
        history = DeviceAgentHistory.remember("B5678", scope: bob, in: history)
        history = DeviceAgentHistory.remember("A9999", scope: alice, in: history)
        precondition(DeviceAgentHistory.agentID(in: history, scope: alice) == "A9999")
        precondition(DeviceAgentHistory.agentID(in: history, scope: bob) == "B5678")
        history = DeviceAgentHistory.remember(nil, scope: alice, in: history)
        precondition(DeviceAgentHistory.agentID(in: history, scope: alice) == nil)
        precondition(DeviceAgentHistory.agentID(in: history, scope: bob) == "B5678")
        precondition(DeviceAgentHistory.agentID(in: history, scope: "https://two.example\nbob") == nil)
        let first = ConsoleAgent(dataQueryEnabled: true, modules: .init(workshop: nil, proxy: .init(version: 1, lan: nil)), id: "A1234", name: "工作电脑", online: true,
                                 lastSeen: "2026-11-14T06:00:00Z",
                                 capabilities: [.init(name: "query.system.metrics", version: 1)])
        let second = ConsoleAgent(id: "B5678", name: "备用电脑", online: true, lastSeen: "", capabilities: nil)
        var inventory = DeviceMonitorInventory()
        precondition(inventory.selectedAgent(id: nil) == nil)
        let unavailable = inventory.selectedAgent(id: first.id)
        precondition(unavailable?.id == first.id && unavailable?.online == false,
                     "The last opened device must remain reachable when the first list request fails")
        precondition(!inventory.hasFetched && inventory.agents.isEmpty,
                     "An unknown list must not be presented as a confirmed empty list")

        inventory.receive([first, second])
        inventory.markOffline(agentID: first.id)
        precondition(inventory.selectedAgent(id: first.id)?.online == false)
        precondition(inventory.selectedAgent(id: first.id)?.supportsProxy == true,
                     "Going offline must preserve the declared module support")
        precondition(inventory.selectedAgent(id: second.id)?.online == true,
                     "One offline Agent must not mark another Agent offline")
        inventory.markOffline()
        let disconnected = inventory.selectedAgent(id: first.id)!
        precondition(!disconnected.online && disconnected.name == first.name
                     && disconnected.dataQueryEnabled == true
                     && disconnected.lastSeen == first.lastSeen
                     && disconnected.capabilities?.first?.name == "query.system.metrics",
                     "Connection failure must retain the device's identity and capabilities")
        precondition(inventory.agents.count == 2 && inventory.agents.allSatisfy { !$0.online })
        inventory.receive([first, second])
        precondition(inventory.selectedAgent(id: first.id)?.online == true,
                     "A successful refresh must recover the online state")

        let suite = "DeviceMonitorInventoryTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = DeviceMonitorInventory.Storage(server: "https://one.example", account: "alice", defaults: defaults)
        storage.save(inventory)
        let reopened = storage.load()
        precondition(reopened.agents.count == 2 && !reopened.hasFetched)
        precondition(reopened.selectedAgent(id: first.id)?.name == first.name)
        precondition(reopened.selectedAgent(id: first.id)?.dataQueryEnabled == true,
                     "Offline/cache round trips must preserve the server permission state")
        precondition(reopened.agents.allSatisfy { !$0.online },
                     "Relaunching offline must not reuse a cached online badge")
        let anotherAccount = DeviceMonitorInventory.Storage(server: "https://one.example", account: "bob", defaults: defaults)
        let anotherServer = DeviceMonitorInventory.Storage(server: "https://two.example", account: "alice", defaults: defaults)
        precondition(anotherAccount.load().agents.isEmpty && anotherServer.load().agents.isEmpty,
                     "Cached devices must be isolated by server and account")

        inventory.receive([])
        precondition(inventory.hasFetched && inventory.selectedAgent(id: first.id) == nil,
                     "A successful empty response is the evidence that a device was removed")
        inventory.markOffline()
        precondition(inventory.selectedAgent(id: first.id) == nil,
                     "A later connection failure must not resurrect a removed device")
        storage.save(inventory)
        precondition(storage.load().agents.isEmpty, "Confirmed removal must replace the cached list")
        defaults.set(Data("invalid".utf8), forKey: storage.key)
        precondition(storage.load().selectedAgent(id: first.id)?.online == false,
                     "An unreadable cache must still preserve the selected device")

        precondition(DeviceMonitorFailure.message(for: URLError(.badURL)).contains("连接地址无效"))
        precondition(DeviceMonitorFailure.message(for: URLError(.timedOut)).contains("超时"))
        for code: URLError.Code in [.notConnectedToInternet, .cannotConnectToHost, .networkConnectionLost] {
            precondition(DeviceMonitorFailure.message(for: URLError(code)).contains("无法连接服务器"))
        }
        print("Device monitor offline, recovery, removal, cache isolation and error message tests passed")
    }
}
