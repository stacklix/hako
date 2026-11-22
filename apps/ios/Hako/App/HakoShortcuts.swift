import AppIntents
import Foundation

struct SyncHakoDataIntent: AppIntent, HakoDataSyncIntent {
    static var title: LocalizedStringResource = "同步 Hako 数据"
    static var description = IntentDescription("在后台更新各子应用数据，包括投资行情、到期定投和每日快照，以及每周日的记账投资数据备份，并汇总执行结果。")
    static var openAppWhenRun = false
    static func manualExecution() -> Bool { false }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = try await synchronizeData()
        return .result(dialog: IntentDialog(stringLiteral: result))
    }
}

struct ManualSyncHakoDataIntent: AppIntent, HakoDataSyncIntent {
    static var title: LocalizedStringResource = "立即同步 Hako 数据"
    // Only the in-app button uses this action; external entry points use SyncHakoDataIntent.
    static var isDiscoverable = false
    static var openAppWhenRun = false
    static func manualExecution() -> Bool { true }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = try await synchronizeData()
        return .result(dialog: IntentDialog(stringLiteral: result))
    }
}

protocol HakoDataSyncIntent: LongRunningIntent, CancellableIntent {
    static func manualExecution() -> Bool
}

extension HakoDataSyncIntent {
    @MainActor func synchronizeData() async throws -> String {
        let cancellation = HakoExecutionCancellation()
        do {
            let result = try await performBackgroundTask {
                try await HakoExecutionDiagnostics.cancellation.withValue(cancellation) {
                    try await HakoShortcutRegistry.run("同步 Hako 数据", manual: Self.manualExecution(), progress: { task, stage, completed, total in
                        progress.totalUnitCount = Int64(total)
                        progress.completedUnitCount = Int64(completed)
                        progress.localizedDescription = "同步 Hako 数据"
                        progress.localizedAdditionalDescription = "\(task) · \(stage)（\(completed)/\(total)）"
                    })
                }
            } onCancel: { reason in
                let detail: String
                switch reason {
                case .timeout: detail = "系统结束后台执行：超过允许的执行时间或未及时报告进度。"
                case .userCancelled: detail = "用户取消了快捷指令。"
                default: detail = "系统取消了快捷指令（\(reason.debugDescription)）。"
                }
                cancellation.record(detail)
            }
            return result
        } catch {
            // The system may deliver its reason after the inner operation unwinds.
            HakoShortcutRegistry.recordIntentCancellation(cancellation)
            throw error
        }
    }
}

struct HakoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SyncHakoDataIntent(), phrases: ["用\(.applicationName)同步数据"], shortTitle: "同步 Hako 数据", systemImageName: "arrow.triangle.2.circlepath")
    }
}
