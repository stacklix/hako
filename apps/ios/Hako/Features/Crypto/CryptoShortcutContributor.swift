enum CryptoShortcutContributor {
    @MainActor static func registerShortcuts(in registry: HakoShortcutRegistry) {
        registry.register("加密资产") {
            let store = CryptoStore.shared
            return try await store.collectAndSynchronize()
        }
    }
}
