import Foundation

enum AppNetworkConfigurationStore {
    static let storageKey = "hako.network.configuration"
    static func load(defaults: UserDefaults) -> LocalNetworkConfiguration {
        if let data = defaults.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode(LocalNetworkConfiguration.self, from: data) { return saved }
        // The user requested moving the update Wi-Fi list into the host module.
        var value = LocalNetworkConfiguration()
        if let data = defaults.data(forKey: "choreUpdateWiFiSSIDs"),
           let ssids = try? JSONDecoder().decode([String].self, from: data) { value.ssids = ssids }
        else if let ssid = defaults.string(forKey: "choreUpdateWiFiSSID"), !ssid.isEmpty { value.ssids = [ssid] }
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: storageKey)
            defaults.removeObject(forKey: "choreUpdateWiFiSSIDs")
            defaults.removeObject(forKey: "choreUpdateWiFiSSID")
        }
        return value
    }

}
