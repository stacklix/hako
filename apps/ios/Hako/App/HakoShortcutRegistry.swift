import Foundation

@MainActor final class HakoShortcutRegistry {
    typealias Progress = @MainActor @Sendable (_ task: String, _ stage: String, _ completed: Int, _ total: Int) -> Void
    private static let shared: HakoShortcutRegistry = {
        let registry = HakoShortcutRegistry(history: .shared)
        HakoApplications.registerShortcuts(in: registry)
        return registry
    }()

    private let history: HakoShortcutHistory

    init(history: HakoShortcutHistory) { self.history = history }

    private var callbacks: [String: @MainActor () async throws -> String] = [:]

    static var availableTaskNames: [String] { shared.registeredTaskNames }
    var registeredTaskNames: [String] { callbacks.keys.sorted() }

    func register(_ name: String, run: @escaping @MainActor () async throws -> String) {
        callbacks[name] = run
    }

    static func run(_ title: String, names: Set<String>? = nil, manual: Bool = false, progress: Progress? = nil) async throws -> String {
        try await shared.runCallbacks(title: title, names: names, manual: manual, progress: progress)
    }

    static func retry(_ id: UUID) async throws -> String {
        try await shared.retryRun(id)
    }

    static func recordIntentCancellation(_ context: HakoExecutionCancellation) {
        shared.history.recordCancellation(context)
    }

    func retryRun(_ id: UUID) async throws -> String {
        guard let run = history.runs.first(where: { $0.id == id }), run.status.canRetry else {
            throw HakoError(message: "只能重试失败、已取消或已中断的执行记录。")
        }
        let names = run.steps.filter { ![.succeeded, .skipped].contains($0.status) }.map(\.name)
        guard !names.isEmpty else { throw HakoError(message: "此记录没有尚未完成的子任务，无需重试。") }
        guard names.allSatisfy({ callbacks[$0] != nil }) else {
            throw HakoError(message: "部分子任务已不可用，无法重试这条记录。")
        }
        return try await runCallbacks(title: run.name, retryRunID: id, names: Set(names), manual: true)
    }

    func runCallbacks(title: String, retryRunID: UUID? = nil, names: Set<String>? = nil, manual: Bool = false, progress: Progress? = nil) async throws -> String {
        guard !history.runs.contains(where: { $0.status == .running }) else {
            throw HakoError(message: "已有快捷指令正在执行，请稍后重试。")
        }
        let selected = names ?? Set(callbacks.keys)
        if selected.isEmpty || !selected.allSatisfy({ callbacks[$0] != nil }) {
            throw HakoError(message: "没有可用的快捷指令任务。")
        }
        let ordered = callbacks.filter { selected.contains($0.key) }.sorted { $0.key < $1.key }
        let runID: UUID
        if let retryRunID {
            guard history.beginRetry(retryRunID) else { throw HakoError(message: "这条记录暂时无法重试。") }
            runID = retryRunID
        } else {
            runID = history.start(title, steps: ordered.map(\.key), source: manual ? .manual : .shortcuts)
        }
        HakoExecutionDiagnostics.cancellation.get()?.bind(to: runID)
        var status = HakoShortcutRun.Status.failed
        defer { history.finish(runID, status: Task.isCancelled ? .cancelled : status) }
        guard !callbacks.isEmpty else { throw HakoError(message: "没有已注册的同步任务。") }
        var results: [String] = []
        var failed = false
        var completed = 0
        for (position, callback) in ordered.enumerated() {
            let (name, run) = callback
            try Task.checkCancellation()
            guard let attemptID = history.recordStep(name, status: .running, runID: runID) else { continue }
            HakoExecutionDiagnostics.cancellation.get()?.bind(step: name, attemptID: attemptID)
            let record: HakoExecutionDiagnostics.Sink = { [history] event in
                history.appendEvent(event, step: name, runID: runID, attemptID: attemptID)
                progress?(name, event.stage + "：" + event.state.rawValue, position, ordered.count)
            }
            let execution = HakoExecutionEvent(stage: retryRunID == nil ? "执行子任务" : "重试子任务", state: .started, detail: "")
            do {
                // Each child owns its cancellation state. Whole-run cancellation
                // still propagates to the active child through the handler below.
                let child = Task { @MainActor in
                    do {
                        return try await HakoExecutionDiagnostics.context.withValue(record) {
                            try Task.checkCancellation()
                            record(execution)
                            HakoExecutionDiagnostics.record("触发来源", detail: retryRunID == nil
                                ? (manual ? HakoShortcutRun.TriggerSource.manual.title : HakoShortcutRun.TriggerSource.shortcuts.title)
                                : "App 内触发（重试）")
                            HakoExecutionDiagnostics.environment()
                            let result = try await HakoShortcutExecution.manual.withValue(manual) { try await run() }
                            try Task.checkCancellation()
                            return result
                        }
                    } catch {
                        if Task.isCancelled { throw CancellationError() }
                        throw error
                    }
                }
                let result = try await withTaskCancellationHandler {
                    try await child.value
                } onCancel: { child.cancel() }
                results.append("\(name)：\(result)")
                record(HakoExecutionEvent(id: execution.id, stage: execution.stage, state: .succeeded, detail: "执行成功。"))
                history.recordStep(name, status: .succeeded, runID: runID, message: result)
                completed += 1
            } catch let skip as HakoShortcutSkip where !Task.isCancelled && HakoExecutionDiagnostics.cancellation.get()?.reason == nil {
                results.append("\(name)：已跳过，\(skip.reason)")
                record(HakoExecutionEvent(id: execution.id, stage: execution.stage, state: .info, detail: "已跳过：" + skip.reason))
                history.recordStep(name, status: .skipped, runID: runID, message: skip.reason)
            } catch {
                let wholeRunCancelled = Task.isCancelled || HakoExecutionDiagnostics.cancellation.get()?.reason != nil
                let cancelled = error is CancellationError || wholeRunCancelled
                let detail = HakoExecutionDiagnostics.failure(error)
                record(HakoExecutionEvent(id: execution.id, stage: execution.stage, state: cancelled ? .cancelled : .failed, detail: detail))
                HakoExecutionDiagnostics.context.withValue(record) { HakoExecutionDiagnostics.environment(cancelled ? "取消时执行环境" : "失败时执行环境") }
                history.recordStep(name, status: cancelled ? .cancelled : .failed, runID: runID, message: detail)
                if wholeRunCancelled {
                    status = .cancelled
                    throw CancellationError()
                }
                failed = true
                results.append("\(name)\(cancelled ? "已取消" : "失败")：\(error.localizedDescription)")
            }
            progress?(name, "子任务已处理", position + 1, ordered.count)
        }
        try Task.checkCancellation()
        let summary = results.joined(separator: "\n")
        if failed { throw HakoError(message: summary) }
        status = completed == 0 ? .skipped : .succeeded
        return summary
    }
}

