import Foundation
import Combine
import Network
import NetworkExtension

@MainActor final class AppNetworkService: ObservableObject, LocalNetworkProviding {
    static let shared = AppNetworkService()
    static let storageKey = AppNetworkConfigurationStore.storageKey
    @Published private(set) var configuration: LocalNetworkConfiguration
    @Published private(set) var currentSSID: String?
    @Published private(set) var usesWiFi = false
    private let defaults: UserDefaults
    private let monitor = NWPathMonitor()
    private let changed = PassthroughSubject<Void, Never>()
    private var pathGeneration = UUID()
    var changes: AnyPublisher<Void, Never> { changed.eraseToAnyPublisher() }
    var isLocal: Bool { configuration.isLocal(ssid: currentSSID, usesWiFi: usesWiFi) }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        configuration = AppNetworkConfigurationStore.load(defaults: defaults)
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pathGeneration = UUID()
                self.usesWiFi = path.status == .satisfied && path.usesInterfaceType(.wifi)
                self.currentSSID = nil
                self.changed.send()
                await self.refresh()
            }
        }
        monitor.start(queue: DispatchQueue(label: "me.stackli.hako.network"))
    }

    func save(_ value: LocalNetworkConfiguration) throws {
        guard value.endpoints.values.allSatisfy(\.isValid) else { throw HakoError(message: "请输入有效的局域网 IP 和端口。") }
        let data = try JSONEncoder().encode(value)
        defaults.set(data, forKey: Self.storageKey)
        configuration = value
        changed.send()
    }

    func refresh() async {
        let generation = pathGeneration
        let ssid = await NEHotspotNetwork.fetchCurrent()?.ssid
        guard !Task.isCancelled, generation == pathGeneration else { return }
        let unchanged = currentSSID == nil && ssid == nil || currentSSID.flatMap { old in ssid.map { old.utf8.elementsEqual($0.utf8) } } == true
        if !unchanged { currentSSID = ssid; changed.send() }
    }

    func endpoint(for application: LocalNetworkApplication) async -> LocalNetworkEndpoint? {
        await refresh()
        guard !Task.isCancelled else { return nil }
        return configuration.endpoint(for: application, ssid: currentSSID, usesWiFi: usesWiFi)
    }
}
