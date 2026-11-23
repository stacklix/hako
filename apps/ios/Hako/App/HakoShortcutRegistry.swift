import Foundation

@MainActor final class HakoShortcutRegistry {
    typealias Progress = @MainActor @Sendable (_ task: String, _ stage: String, _ completed: Int, _ total: Int) -> Void
    @MainActor private final class OperationProgress {
        var completed = 0
        var remainingChildren: Int
        var activeOperations: [UUID: Set<UUID>] = [:]
        var total: Int { completed + activeOperations.values.reduce(0) { $0 + $1.count } + remainingChildren }
        init(children: Int) { remainingChildren = children }
    }
    private static let shared: HakoShortcutRegistry = {
        let registry = HakoShortcutRegistry(history: .shared)
        HakoApplications.registerShortcuts(in: registry)
        return registry
    }()

    private let history: HakoShortcutHistory

    init(history: HakoShortcutHistory) { self.history = history }

    private struct Registration: Sendable {
        let name: String
        let group: String
        let order: Int
        let run: @MainActor @Sendable () async throws -> String
    }
    private struct ChildResult: Sendable {
        let name: String
        let message: String
        var failed = false
        var succeeded = false
    }
    private var callbacks: [String: Registration] = [:]
    private var registrationErrors: [String] = []

    static var availableTaskNames: [String] { shared.registeredTaskNames }
    var registeredTaskNames: [String] { callbacks.keys.sorted() }

    func register(_ name: String, group: String, order: Int, run: @escaping @MainActor @Sendable () async throws -> String) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, order > 0 else {
            registrationErrors.append("子任务名称、分组不能为空，序号必须大于零。")
            return
        }
        guard callbacks[name] == nil else {
            registrationErrors.append("子任务重复注册：\(name)。")
            return
        }
        guard !callbacks.values.contains(where: { $0.group == group && $0.order == order }) else {
            registrationErrors.append("分组 \(group) 的序号 \(order) 重复。")
            return
        }
        callbacks[name] = Registration(name: name, group: group, order: order, run: run)
    }

    static func run(_ title: String, names: Set<String>? = nil, manual: Bool = false, ignoresSchedule: Bool = false, progress: Progress? = nil) async throws -> String {
        try await shared.runCallbacks(title: title, names: names, manual: manual, ignoresSchedule: ignoresSchedule, progress: progress)
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

    func runCallbacks(title: String, retryRunID: UUID? = nil, names: Set<String>? = nil, manual: Bool = false, ignoresSchedule: Bool = false, progress: Progress? = nil) async throws -> String {
        guard registrationErrors.isEmpty else { throw HakoError(message: registrationErrors.joined(separator: "\n")) }
        guard !history.runs.contains(where: { $0.status == .running }) else {
            throw HakoError(message: "已有快捷指令正在执行，请稍后重试。")
        }
        let selected = names ?? Set(callbacks.keys)
        if selected.isEmpty || !selected.allSatisfy({ callbacks[$0] != nil }) {
            throw HakoError(message: "没有可用的快捷指令任务。")
        }
        guard !ignoresSchedule || (manual && names?.count == 1 && retryRunID == nil) else {
            throw HakoError(message: "只有明确选择单个子任务手动执行时，才能跳过执行计划。")
        }
        let ordered = callbacks.values.filter { selected.contains($0.name) }.sorted {
            $0.group == $1.group ? $0.order < $1.order : $0.group < $1.group
        }
        let runID: UUID
        if let retryRunID {
            guard history.beginRetry(retryRunID) else { throw HakoError(message: "这条记录暂时无法重试。") }
            runID = retryRunID
        } else {
            runID = history.start(title, steps: ordered.map(\.name), source: manual ? .manual : .shortcuts)
        }
        HakoExecutionDiagnostics.cancellation.get()?.bind(to: runID)
        var status = HakoShortcutRun.Status.failed
        defer {
            history.finish(runID, status: Task.isCancelled || HakoExecutionDiagnostics.cancellation.get()?.reason != nil ? .cancelled : status)
        }
        guard !callbacks.isEmpty else { throw HakoError(message: "没有已注册的同步任务。") }
        // Count actual operation completions as well as whole children. Reporting
        // only the child index leaves a long collection at zero progress even
        // while many requests have completed. The total grows as work is found.
        let operationProgress = OperationProgress(children: ordered.count)
        defer { operationProgress.activeOperations.removeAll() }
        let groups = Dictionary(grouping: ordered, by: \.group)
        let results = try await withThrowingTaskGroup(of: [ChildResult].self) { tasks in
            for key in groups.keys.sorted() {
                let registrations = groups[key]!
                tasks.addTask {
                    try await self.runGroup(registrations, runID: runID, retry: retryRunID != nil,
                                            manual: manual, ignoresSchedule: ignoresSchedule,
                                            operationProgress: operationProgress, progress: progress)
                }
            }
            var results: [ChildResult] = []
            for try await result in tasks { results += result }
            return results
        }
        try checkCancellation()
        // Completion order varies across groups; summaries retain registration order.
        let byName = Dictionary(uniqueKeysWithValues: results.map { ($0.name, $0) })
        let summary = ordered.compactMap { byName[$0.name]?.message }.joined(separator: "\n")
        if results.contains(where: \.failed) { throw HakoError(message: summary) }
        status = results.contains(where: \.succeeded) ? .succeeded : .skipped
        return summary
    }

    private func checkCancellation() throws {
        try Task.checkCancellation()
        if HakoExecutionDiagnostics.cancellation.get()?.reason != nil { throw CancellationError() }
    }

    private func runGroup(_ registrations: [Registration], runID: UUID, retry: Bool,
                          manual: Bool, ignoresSchedule: Bool, operationProgress: OperationProgress,
                          progress: Progress?) async throws -> [ChildResult] {
        var results: [ChildResult] = []
        for callback in registrations {
            try checkCancellation()
            let result = try await runChild(callback, runID: runID, retry: retry, manual: manual,
                                            ignoresSchedule: ignoresSchedule, operationProgress: operationProgress,
                                            progress: progress)
            results.append(result)
        }
        return results
    }

    private func runChild(_ callback: Registration, runID: UUID, retry: Bool, manual: Bool,
                          ignoresSchedule: Bool, operationProgress: OperationProgress,
                          progress: Progress?) async throws -> ChildResult {
        let name = callback.name
        guard let attemptID = history.recordStep(name, status: .running, runID: runID) else {
            throw HakoError(message: "无法记录子任务执行状态。")
        }
        HakoExecutionDiagnostics.cancellation.get()?.bind(step: name, attemptID: attemptID)
        operationProgress.activeOperations[attemptID] = []
        var wholeRunCancelled = false
        defer {
            HakoExecutionDiagnostics.cancellation.get()?.finish(step: name, attemptID: attemptID,
                                                                keepForCancellation: wholeRunCancelled)
            // Only this child's unfinished operations are removed.
            operationProgress.activeOperations[attemptID] = nil
            operationProgress.completed += 1
            operationProgress.remainingChildren -= 1
            progress?(name, "子任务已处理", operationProgress.completed, operationProgress.total)
        }
        let record: HakoExecutionDiagnostics.Sink = { [history] event in
            history.appendEvent(event, step: name, runID: runID, attemptID: attemptID)
            guard operationProgress.activeOperations[attemptID] != nil else { return }
            if !["执行子任务", "重试子任务"].contains(event.stageTitle) {
                if event.state == .started { operationProgress.activeOperations[attemptID]?.insert(event.id) }
                else if [.succeeded, .failed, .cancelled].contains(event.state),
                        operationProgress.activeOperations[attemptID]?.remove(event.id) != nil { operationProgress.completed += 1 }
            }
            progress?(name, event.stageTitle + "：" + event.state.rawValue,
                      operationProgress.completed, operationProgress.total)
        }
        let execution = HakoExecutionEvent(stage: retry ? "重试子任务" : "执行子任务", state: .started, detail: "")
        do {
            // Each child owns its cancellation state. Whole-run cancellation
            // still propagates to the active child through the handler below.
            let child = Task { @MainActor in
                do {
                    return try await HakoExecutionDiagnostics.context.withValue(record) {
                        try Task.checkCancellation()
                        record(execution)
                        HakoExecutionDiagnostics.record("触发来源", detail: !retry
                            ? (manual ? HakoShortcutRun.TriggerSource.manual.title : HakoShortcutRun.TriggerSource.shortcuts.title)
                            : "App 内触发（重试）")
                        HakoExecutionDiagnostics.environment()
                        let result = try await HakoShortcutExecution.manual.withValue(manual) {
                            try await HakoShortcutExecution.scheduleOverride.withValue(ignoresSchedule) { try await callback.run() }
                        }
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
            try checkCancellation()
            record(HakoExecutionEvent(id: execution.id, stage: execution.stage, state: .succeeded, detail: "执行成功。"))
            history.recordStep(name, status: .succeeded, runID: runID, message: result)
            return ChildResult(name: name, message: "\(name)：\(result)", succeeded: true)
        } catch let skip as HakoShortcutSkip where !Task.isCancelled && HakoExecutionDiagnostics.cancellation.get()?.reason == nil {
            record(HakoExecutionEvent(id: execution.id, stage: execution.stage, state: .info, detail: "已跳过：" + skip.reason))
            history.recordStep(name, status: .skipped, runID: runID, message: skip.reason)
            return ChildResult(name: name, message: "\(name)：已跳过，\(skip.reason)")
        } catch {
            wholeRunCancelled = Task.isCancelled || HakoExecutionDiagnostics.cancellation.get()?.reason != nil
            let cancelled = error is CancellationError || wholeRunCancelled
            let detail = HakoExecutionDiagnostics.failure(error)
            record(HakoExecutionEvent(id: execution.id, stage: execution.stage, state: cancelled ? .cancelled : .failed, detail: detail))
            HakoExecutionDiagnostics.context.withValue(record) { HakoExecutionDiagnostics.environment(cancelled ? "取消时执行环境" : "失败时执行环境") }
            history.recordStep(name, status: cancelled ? .cancelled : .failed, runID: runID, message: detail)
            if wholeRunCancelled {
                throw CancellationError()
            }
            return ChildResult(name: name, message: "\(name)\(cancelled ? "已取消" : "失败")：\(error.localizedDescription)", failed: true)
        }
    }
}
