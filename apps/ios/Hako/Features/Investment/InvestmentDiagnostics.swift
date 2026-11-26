import Foundation

// Reuse the existing diagnostic events and redacted HTTP log. Each operation gets
// a task-local identity, so overlapping app and Shortcut operations stay distinct.
enum InvestmentDiagnostics {
    @MainActor final class Operation {
        let id = UUID()
        let upstream: HakoExecutionDiagnostics.Sink?
        let store: HakoLogStore
        private var starts: [UUID: Date] = [:]

        init(upstream: HakoExecutionDiagnostics.Sink?, store: HakoLogStore) {
            self.upstream = upstream
            self.store = store
        }

        func append(_ event: HakoExecutionEvent) {
            upstream?(event)
            var detail = "运行 ID：\(id.uuidString)\n步骤 ID：\(event.id.uuidString)"
            if event.state == .started { starts[event.id] = event.time }
            else if let start = starts.removeValue(forKey: event.id) {
                detail += String(format: "\n耗时：%.3f 秒", max(0, event.time.timeIntervalSince(start)))
            }
            if !event.detail.isEmpty { detail += "\n" + event.detail }
            let level: HakoLogLevel = event.state == .failed ? .error : event.state == .cancelled ? .warning : .info
            store.append(source: .investment, level: level,
                         message: event.stage + " · " + event.state.rawValue, detail: detail, fullDetail: true)
        }
    }

    static let current = TaskLocal<Operation?>(wrappedValue: nil)

    @MainActor static func run<T>(_ title: String, independent: Bool = false,
                                  store: HakoLogStore = .shared,
                                  operation: () async throws -> T) async rethrows -> T {
        if current.get() != nil, !independent {
            return try await HakoExecutionDiagnostics.measure(title, operation: operation)
        }
        let prior: HakoExecutionDiagnostics.Sink?
        if let parent = current.get() { prior = parent.upstream }
        else { prior = HakoExecutionDiagnostics.context.get() }
        let run = Operation(upstream: prior, store: store)
        return try await current.withValue(run) {
            try await HakoExecutionDiagnostics.context.withValue({ run.append($0) }) {
                try await HTTPTransport.logSource.withValue(.investment) {
                    try await HTTPTransport.logContext.withValue("投资运行 ID：" + run.id.uuidString) {
                        HakoExecutionDiagnostics.environment()
                        return try await HakoExecutionDiagnostics.measure(title, operation: operation)
                    }
                }
            }
        }
    }
}
