import Foundation
import Combine
import Network
import NetworkExtension

@MainActor final class AppNetworkService: ObservableObject, LocalNetworkProviding {
    static let shared = AppNetworkService()
    static let storageKey = AppNetworkConfigurationStore.storageKey
    @Published private(set) var ssids: [String]
    @Published private(set) var currentSSID: String?
    @Published private(set) var usesWiFi = false
    private let defaults: UserDefaults
    private let monitor = NWPathMonitor()
    private let changed = PassthroughSubject<Void, Never>()
    private var pathGeneration = UUID()
    private let ssidCache = NetworkSSIDCache { await NEHotspotNetwork.fetchCurrent()?.ssid }
    var changes: AnyPublisher<Void, Never> { changed.eraseToAnyPublisher() }
    var isLocal: Bool { LocalNetworkConfiguration(ssids: ssids).isLocal(ssid: currentSSID, usesWiFi: usesWiFi) }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ssids = AppNetworkConfigurationStore.load(defaults: defaults).ssids
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pathGeneration = UUID()
                self.ssidCache.invalidate()
                self.usesWiFi = path.status == .satisfied && path.usesInterfaceType(.wifi)
                self.currentSSID = nil
                self.changed.send()
                await self.refresh()
            }
        }
        monitor.start(queue: DispatchQueue(label: "me.stackli.hako.network"))
    }

    func save(ssids: [String]) throws {
        var value = AppNetworkConfigurationStore.load(defaults: defaults)
        value.ssids = ssids
        let data = try JSONEncoder().encode(value)
        defaults.set(data, forKey: Self.storageKey)
        self.ssids = ssids
        changed.send()
    }

    func refresh() async {
        let generation = pathGeneration
        let ssid = await ssidCache.value(usesWiFi: usesWiFi, generation: generation)
        guard !Task.isCancelled, generation == pathGeneration else { return }
        let unchanged = currentSSID == nil && ssid == nil || currentSSID.flatMap { old in ssid.map { old.utf8.elementsEqual($0.utf8) } } == true
        if !unchanged { currentSSID = ssid; changed.send() }
    }

}
