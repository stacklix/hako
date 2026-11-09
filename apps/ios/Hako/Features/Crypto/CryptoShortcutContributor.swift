enum CryptoShortcutContributor {
    @MainActor static func registerShortcuts(in registry: HakoShortcutRegistry) {
        registry.register("加密资产") {
            let store = CryptoStore.shared
            let result = await store.trigger()
            if store.message != nil { throw HakoError(message: result) }
            return result
        }
    }
}
