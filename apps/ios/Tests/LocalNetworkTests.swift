import Foundation

@main struct LocalNetworkTests {
    static func main() throws {
        let timeout = WorkshopNetworkConfiguration.connectionFailureMessage(URLError(.timedOut))
        precondition(timeout.contains("未收到电脑") && timeout.contains("-1001"))
        precondition(WorkshopNetworkConfiguration.connectionFailureMessage(URLError(.cannotConnectToHost)).contains("此端口"))
        precondition(WorkshopNetworkConfiguration.connectionFailureMessage(URLError(.notConnectedToInternet)).contains("局域网权限"))
        precondition(WorkshopNetworkConfiguration.connectionFailureMessage(WorkshopNetworkConfiguration.ConnectionError.wrongComputer)
            == WorkshopNetworkConfiguration.ConnectionError.wrongComputer.localizedDescription)
        let endpoint = LocalNetworkEndpoint(ip: "192.168.0.10", port: 8005)!
        precondition(endpoint.url(path: "/agents")?.absoluteString == "ws://192.168.0.10:8005/agents")
        precondition(LocalNetworkEndpoint(ip: "fd12::1234", port: 8005)?.url()?.absoluteString == "ws://[fd12::1234]:8005/")
        for ip in ["8.8.8.8", "0.0.0.0", "127.0.0.1", "192.168.0.999", "192.168.0.1/path", "example.com", "2001:4860:4860::8888"] {
            precondition(LocalNetworkEndpoint(ip: ip, port: 8005) == nil, "Only literal local IP addresses can be configured")
        }
        for port in [0, -1, 65536] { precondition(LocalNetworkEndpoint(ip: endpoint.ip, port: port) == nil) }
        var configuration = LocalNetworkConfiguration(ssids: ["Home", "家里 Wi-Fi", "é"], endpoints: ["codeWorkshop": endpoint])
        precondition(configuration.endpoint(for: .codeWorkshop, ssid: "Home", usesWiFi: true) == endpoint)
        for ssid in [nil, "", "home", "Home ", "Public Wi-Fi", "e\u{301}"] as [String?] {
            precondition(configuration.endpoint(for: .codeWorkshop, ssid: ssid, usesWiFi: true) == nil)
        }
        precondition(configuration.endpoint(for: .codeWorkshop, ssid: "Home", usesWiFi: false) == nil)
        configuration.endpoints = [:]
        precondition(configuration.endpoint(for: .codeWorkshop, ssid: "Home", usesWiFi: true) == nil)
        let name = "hako-local-network-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(try JSONEncoder().encode(configuration), forKey: AppNetworkConfigurationStore.storageKey)
        let second = LocalNetworkEndpoint(ip: "192.168.0.20", port: 9005)!
        try WorkshopNetworkConfiguration.save(endpoint, agentID: "A", namespace: "server-one", defaults: defaults)
        try WorkshopNetworkConfiguration.save(second, agentID: "B", namespace: "server-one", defaults: defaults)
        try WorkshopNetworkConfiguration.save(second, agentID: "A", namespace: "server-two", defaults: defaults)
        precondition(WorkshopNetworkConfiguration.load(agentID: "A", namespace: "server-one", defaults: defaults) == endpoint)
        precondition(WorkshopNetworkConfiguration.load(agentID: "B", namespace: "server-one", defaults: defaults) == second)
        precondition(WorkshopNetworkConfiguration.load(agentID: "A", namespace: "server-two", defaults: defaults) == second)
        precondition(WorkshopNetworkConfiguration.load(agentID: "unknown", namespace: "server-one", defaults: defaults) == nil,
            "An unconfigured computer must never inherit another computer's address")
        precondition(AppNetworkConfigurationStore.load(defaults: defaults).ssids == configuration.ssids,
            "Subapplication address changes must preserve the host Wi-Fi list")
        try WorkshopNetworkConfiguration.save(nil, agentID: "A", namespace: "server-one", defaults: defaults)
        precondition(WorkshopNetworkConfiguration.load(agentID: "A", namespace: "server-one", defaults: defaults) == nil)
        precondition(WorkshopNetworkConfiguration.load(agentID: "B", namespace: "server-one", defaults: defaults) == second)
        precondition(WorkshopNetworkConfiguration.load(agentID: "A", namespace: "server-two", defaults: defaults) == second)
        precondition(AppNetworkConfigurationStore.load(defaults: defaults).ssids == configuration.ssids)
        let hello = Data(#"{"kind":"welcome","protocol":"hako.workshop/1","computerId":"A"}"#.utf8)
        try WorkshopNetworkConfiguration.requireComputer(hello, agentID: "A")
        do {
            try WorkshopNetworkConfiguration.requireComputer(hello, agentID: "B")
            preconditionFailure("A direct connection must reject the wrong computer before sending requests")
        } catch WorkshopNetworkConfiguration.ConnectionError.wrongComputer { }
        defaults.removeObject(forKey: AppNetworkConfigurationStore.storageKey)
        defaults.set(try JSONEncoder().encode(["Home", "家里 Wi-Fi"]), forKey: "choreUpdateWiFiSSIDs")
        defaults.set("Retired", forKey: "choreUpdateWiFiSSID")
        let migrated = AppNetworkConfigurationStore.load(defaults: defaults)
        precondition(migrated.ssids == ["Home", "家里 Wi-Fi"] && migrated.endpoints.isEmpty)
        precondition(defaults.object(forKey: "choreUpdateWiFiSSIDs") == nil && defaults.object(forKey: "choreUpdateWiFiSSID") == nil)
        precondition(AppNetworkConfigurationStore.load(defaults: defaults) == migrated, "Migration must run once without losing the new configuration")
        defaults.removeObject(forKey: AppNetworkConfigurationStore.storageKey)
        defaults.set("Single Wi-Fi", forKey: "choreUpdateWiFiSSID")
        precondition(AppNetworkConfigurationStore.load(defaults: defaults).ssids == ["Single Wi-Fi"])
        print("PASS: Wi-Fi-only host endpoint resolution, exact SSID matching, local IP/port validation and update Wi-Fi migration")
    }
}
