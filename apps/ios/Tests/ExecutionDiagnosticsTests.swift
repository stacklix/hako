import Foundation

@MainActor private final class Events {
    var values: [HakoExecutionEvent] = []
    func append(_ event: HakoExecutionEvent) { values.append(event) }
}

@main struct ExecutionDiagnosticsTests {
    @MainActor static func main() async throws {
        let outer = Events(), inner = Events()
        try await HakoExecutionDiagnostics.context.withValue({ outer.append($0) }) {
            let result = HakoExecutionDiagnostics.measure("读取设备身份记录") { 42 }
            precondition(result == 42)
            let value = try await HakoExecutionDiagnostics.measure("读取投资账本") {
                try await Task.sleep(for: .milliseconds(1))
                return "loaded"
            }
            precondition(value == "loaded")
            HakoExecutionDiagnostics.context.withValue({ inner.append($0) }) {
                HakoExecutionDiagnostics.record("独立任务")
            }
            do {
                try HakoExecutionDiagnostics.measure("读取服务端登录会话") {
                    throw NSError(domain: NSOSStatusErrorDomain, code: -25308,
                                  userInfo: [NSLocalizedDescriptionKey: "读取失败 Authorization: Bearer fake-token-123"])
                }
                preconditionFailure("Error was swallowed")
            } catch let error as NSError { precondition(error.code == -25308) }
            do {
                try await HakoExecutionDiagnostics.measure("取消操作") {
                    await Task.yield()
                    throw CancellationError()
                }
                preconditionFailure("Cancellation was swallowed")
            } catch is CancellationError {}
        }
        precondition(inner.values.count == 1 && inner.values[0].stage == "独立任务")
        precondition(outer.values.count == 8 && !outer.values.contains { $0.stage == "独立任务" })
        let failure = outer.values.first { $0.state == .failed }!
        precondition(failure.stage == "读取服务端登录会话")
        precondition(failure.detail.contains("-25308") && failure.detail.contains("errSecInteractionNotAllowed"))
        precondition(!failure.detail.contains("fake-token-123"), "Token leaked into diagnostics")
        precondition(outer.values.last?.state == .cancelled)
        let count = outer.values.count
        HakoExecutionDiagnostics.record("无接收器")
        precondition(outer.values.count == count && HakoExecutionDiagnostics.sink == nil)
        let data = try JSONEncoder().encode(outer.values)
        let restored = try JSONDecoder().decode([HakoExecutionEvent].self, from: data)
        precondition(restored.map(\.id) == outer.values.map(\.id))
        print("PASS: diagnostic stages, timing, OSStatus, redaction, cancellation, task scope and persistence")
    }
}
