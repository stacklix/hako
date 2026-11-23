enum CryptoShortcutContributor {
    @MainActor static func registerShortcuts(in registry: HakoShortcutRegistry) {
        registry.register("加密资产", group: "crypto", order: 1) {
            let store = CryptoStore.shared
            return try await store.collectAndSynchronize()
        }
    }
}
