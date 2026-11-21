import AppIntents
import Foundation

struct SyncHakoDataIntent: AppIntent {
    static var title: LocalizedStringResource = "同步 Hako 数据"
    static var description = IntentDescription("在后台更新各子应用数据，包括投资行情、到期定投和每日快照，以及每周日的记账投资数据备份，并汇总执行结果。")
    static var openAppWhenRun = false

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = try await HakoShortcutRegistry.run("同步 Hako 数据")
        return .result(dialog: IntentDialog(stringLiteral: result))
    }
}

struct HakoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SyncHakoDataIntent(), phrases: ["用\(.applicationName)同步数据"], shortTitle: "同步 Hako 数据", systemImageName: "arrow.triangle.2.circlepath")
    }
}
