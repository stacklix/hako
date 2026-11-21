import Foundation

@MainActor final class HakoShortcutRegistry {
    private static let shared: HakoShortcutRegistry = {
        let registry = HakoShortcutRegistry(history: .shared)
        HakoApplications.registerShortcuts(in: registry)
        return registry
    }()

    private let history: HakoShortcutHistory

    init(history: HakoShortcutHistory) { self.history = history }

    private var callbacks: [String: @MainActor () async throws -> String] = [:]

    func register(_ name: String, run: @escaping @MainActor () async throws -> String) {
        callbacks[name] = run
    }

    static func run(_ title: String, names: Set<String>? = nil, manual: Bool = false) async throws -> String {
        try await shared.runCallbacks(title: title, names: names, manual: manual)
    }

    static func retry(_ id: UUID) async throws -> String {
        try await shared.retryRun(id)
    }

    func retryRun(_ id: UUID) async throws -> String {
        guard let run = history.runs.first(where: { $0.id == id }), run.status == .failed else {
            throw HakoError(message: "只能重试失败的执行记录。")
        }
        let names = run.steps.filter { ![.succeeded, .skipped].contains($0.status) }.map(\.name)
        guard names.allSatisfy({ callbacks[$0] != nil }) else {
            throw HakoError(message: "部分子任务已不可用，无法重试这条记录。")
        }
        return try await runCallbacks(title: run.name, retryRunID: id, names: names.isEmpty ? nil : Set(names), manual: true)
    }

    func runCallbacks(title: String, retryRunID: UUID? = nil, names: Set<String>? = nil, manual: Bool = false) async throws -> String {
        guard !history.runs.contains(where: { $0.status == .running }) else {
            throw HakoError(message: "已有快捷指令正在执行，请稍后重试。")
        }
        let selected = names ?? Set(callbacks.keys)
        if selected.isEmpty || !selected.allSatisfy({ callbacks[$0] != nil }) {
            throw HakoError(message: "没有可用的快捷指令任务。")
        }
        let runID: UUID
        if let retryRunID {
            guard history.beginRetry(retryRunID) else { throw HakoError(message: "这条记录暂时无法重试。") }
            runID = retryRunID
        } else {
            runID = history.start(title)
        }
        var status = HakoShortcutRun.Status.failed
        defer { history.finish(runID, status: Task.isCancelled ? .cancelled : status) }
        guard !callbacks.isEmpty else { throw HakoError(message: "没有已注册的同步任务。") }
        var results: [String] = []
        var failed = false
        var completed = 0
        for (name, run) in callbacks.filter({ selected.contains($0.key) }).sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            guard let attemptID = history.recordStep(name, status: .running, runID: runID) else { continue }
            let record: HakoExecutionDiagnostics.Sink = { [history] event in
                history.appendEvent(event, step: name, runID: runID, attemptID: attemptID)
            }
            do {
                let result = try await HakoExecutionDiagnostics.context.withValue(record) {
                    HakoExecutionDiagnostics.record(retryRunID == nil ? "开始执行子任务" : "重试子任务", state: .started)
                    HakoExecutionDiagnostics.environment()
                    return try await HakoShortcutExecution.manual.withValue(manual) {
                        try await run()
                    }
                }
                results.append("\(name)：\(result)")
                record(HakoExecutionEvent(stage: "子任务结束", state: .succeeded, detail: "执行成功。"))
                history.recordStep(name, status: .succeeded, runID: runID, message: result)
                completed += 1
            } catch let skip as HakoShortcutSkip {
                results.append("\(name)：已跳过，\(skip.reason)")
                record(HakoExecutionEvent(stage: "子任务跳过", state: .info, detail: skip.reason))
                history.recordStep(name, status: .skipped, runID: runID, message: skip.reason)
            } catch is CancellationError {
                status = .cancelled
                record(HakoExecutionEvent(stage: "子任务结束", state: .cancelled, detail: "执行已取消。"))
                history.recordStep(name, status: .cancelled, runID: runID, message: "执行已取消。")
                throw CancellationError()
            } catch {
                failed = true
                results.append("\(name)失败：\(error.localizedDescription)")
                let detail = HakoExecutionDiagnostics.failure(error)
                record(HakoExecutionEvent(stage: "子任务结束", state: .failed, detail: detail))
                history.recordStep(name, status: .failed, runID: runID, message: detail)
            }
        }
        try Task.checkCancellation()
        let summary = results.joined(separator: "\n")
        if failed { throw HakoError(message: summary) }
        status = completed == 0 ? .skipped : .succeeded
        return summary
    }
}

