import Foundation

// The registry contract is tested independently of application services.
@MainActor enum HakoApplications {
    static func registerShortcuts(in registry: HakoShortcutRegistry) {}
}

@main struct HakoShortcutRetryTests {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("runs.json")
        let history = HakoShortcutHistory(fileURL: file)
        let registry = HakoShortcutRegistry(history: history)
        var successfulCalls = 0, failedCalls = 0
        var expiredSink: HakoExecutionDiagnostics.Sink?
        registry.register("A") { successfulCalls += 1; return "ok" }
        registry.register("B") {
            failedCalls += 1
            if failedCalls == 1 { expiredSink = HakoExecutionDiagnostics.sink }
            else { expiredSink?(HakoExecutionEvent(stage: "过期任务日志", state: .info, detail: "不应保存")) }
            HakoExecutionDiagnostics.record("读取服务端登录会话", detail: "Authorization: Bearer fake-secret-456")
            precondition(history.runs[0].status == .running)
            do { _ = try await registry.retryRun(history.runs[0].id); preconditionFailure("Concurrent retry accepted") }
            catch {}
            if failedCalls < 3 { throw HakoError(message: "offline") }
            return "recovered"
        }
        do { _ = try await registry.runCallbacks(title: "同步 Hako 数据"); preconditionFailure("Failure was ignored") }
        catch {}
        let id = history.runs[0].id
        let failedStep = history.runs[0].steps.first { $0.name == "B" }!
        precondition(failedStep.message?.contains("offline") == true && failedStep.finishedAt != nil)
        precondition(failedStep.events?.contains { $0.stage == "读取服务端登录会话" } == true)
        let firstEvents = failedStep.events!.map(\.id)
        precondition(history.runs[0].status == .failed && history.runs[0].steps.count == 2)
        do { _ = try await registry.retryRun(id); preconditionFailure("Retry failure was ignored") }
        catch {}
        precondition(history.runs[0].status == .failed && successfulCalls == 1 && failedCalls == 2)
        _ = try await registry.retryRun(id)
        precondition(history.runs.count == 1 && history.runs[0].id == id)
        precondition(history.runs[0].status == .succeeded && history.runs[0].finishedAt != nil)
        precondition(history.runs[0].steps.count == 2 && history.runs[0].steps.allSatisfy { $0.status == .succeeded })
        precondition(successfulCalls == 1 && failedCalls == 3, "Successful steps must not run again")
        let step = history.runs[0].steps.first { $0.name == "B" }!
        precondition(step.attempts == 3 && step.message == "recovered")
        precondition(firstEvents.allSatisfy { id in step.events!.contains { $0.id == id } }, "Retry erased previous failure logs")
        precondition(!step.events!.contains { $0.stage == "过期任务日志" }, "Late logs contaminated a retry")
        let persisted = try Data(contentsOf: file)
        precondition(!String(decoding: persisted, as: UTF8.self).contains("fake-secret-456"))
        let restored = HakoShortcutHistory(fileURL: file)
        precondition(restored.runs[0].status == .succeeded && restored.runs[0].steps.count == 2)
        precondition(restored.runs[0].steps.first { $0.name == "B" }?.events?.count == step.events?.count)
        do { _ = try await registry.retryRun(id); preconditionFailure("Successful run was retried") }
        catch {}
        precondition(failedCalls == 3)
        let unavailable = history.start("unavailable")
        history.recordStep("removed", status: .failed, runID: unavailable)
        history.finish(unavailable, status: .failed)
        do { _ = try await registry.retryRun(unavailable); preconditionFailure("Unavailable callback accepted") }
        catch {}
        precondition(history.runs[0].status == .failed)
        let capped = history.start("capped")
        let attempt = history.recordStep("bounded", status: .running, runID: capped)!
        for number in 0..<(HakoShortcutHistory.eventCapacity + 3) {
            history.appendEvent(HakoExecutionEvent(stage: "event \(number)", state: .info, detail: ""), step: "bounded", runID: capped, attemptID: attempt)
        }
        precondition(history.runs[0].steps[0].events?.count == HakoShortcutHistory.eventCapacity)
        let interrupted = HakoShortcutHistory(fileURL: file)
        precondition(interrupted.runs[0].status == .interrupted && interrupted.runs[0].steps[0].status == .interrupted)
        precondition(interrupted.runs[0].steps[0].events?.count == HakoShortcutHistory.eventCapacity)
        print("PASS: shortcut retry updates and persists the original record, preserves successful steps, rejects duplicate and unavailable tasks")
    }
}
