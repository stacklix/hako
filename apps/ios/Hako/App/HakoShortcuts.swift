import AppIntents
import Foundation

@MainActor final class HakoShortcutRegistry {
    private static let shared: HakoShortcutRegistry = {
        let registry = HakoShortcutRegistry()
        HakoApplications.registerShortcuts(in: registry)
        return registry
    }()

    private var callbacks: [String: @MainActor () async throws -> String] = [:]

    func register(_ name: String, run: @escaping @MainActor () async throws -> String) {
        callbacks[name] = run
    }

    static func run(_ title: String) async throws -> String {
        try await shared.runCallbacks(title: title)
    }

    private func runCallbacks(title: String) async throws -> String {
        let history = HakoShortcutHistory.shared
        let runID = history.start(title)
        var status = HakoShortcutRun.Status.failed
        defer { history.finish(runID, status: Task.isCancelled ? .cancelled : status) }
        guard !callbacks.isEmpty else { throw HakoError(message: "没有已注册的同步任务。") }
        var results: [String] = []
        var failed = false
        for (name, run) in callbacks.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            do {
                results.append("\(name)：\(try await run())")
                history.recordStep(name, status: .succeeded, runID: runID)
            } catch is CancellationError {
                status = .cancelled
                history.recordStep(name, status: .cancelled, runID: runID)
                throw CancellationError()
            } catch {
                failed = true
                results.append("\(name)失败：\(error.localizedDescription)")
                history.recordStep(name, status: .failed, runID: runID)
            }
        }
        try Task.checkCancellation()
        let summary = results.joined(separator: "\n")
        if failed { throw HakoError(message: summary) }
        status = .succeeded
        return summary
    }
}

struct SyncHakoDataIntent: AppIntent {
    static var title: LocalizedStringResource = "同步 Hako 数据"
    static var description = IntentDescription("在后台运行各子应用注册的同步任务，并汇总结果。")
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
