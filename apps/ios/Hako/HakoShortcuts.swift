import AppIntents

struct HakoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: RecordRecentWeekIntent(), phrases:["用\(.applicationName)获取应用使用时间并同步"],shortTitle:"获取app使用时间并同步",systemImageName:"clock")
        AppShortcut(intent: SyncCryptoAssetsIntent(), phrases:["用\(.applicationName)同步加密资产"],shortTitle:"同步加密资产",systemImageName:"bitcoinsign.circle")
    }
}
