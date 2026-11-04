import AppIntents

struct SyncCryptoAssetsIntent: AppIntent {
    static var title: LocalizedStringResource = "同步加密资产"
    static var description = IntentDescription("统一采集昨日 TRX 合约数据及今日总资产，并同步到私有 GitHub 仓库。当日已成功同步的任务自动跳过。请先配置只读 API 和私有库。")
    static var openAppWhenRun = false
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let store=CryptoStore.shared
        let result=await store.trigger()
        if store.message != nil { throw HakoError(message:result) }
        return .result(dialog:IntentDialog(stringLiteral:result))
    }
}
