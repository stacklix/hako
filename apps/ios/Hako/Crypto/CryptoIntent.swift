import AppIntents

struct SyncCryptoAssetsIntent: AppIntent {
    static var title: LocalizedStringResource = "同步加密资产"
    static var description = IntentDescription("将本机已有的资产缓存同步到私有 GitHub 仓库，不重新查询资产接口。请先进入加密资产页面采集数据，并配置私有库。")
    static var openAppWhenRun = false
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let store=CryptoStore.shared
        let result=await store.trigger()
        if store.message != nil { throw HakoError(message:result) }
        return .result(dialog:IntentDialog(stringLiteral:result))
    }
}
