import Foundation

// The registry contract is tested independently of application services.
@MainActor enum HakoApplications {
    static func registerShortcuts(in registry: HakoShortcutRegistry) {}
}

@main struct HakoShortcutRetryTests {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await checkFailureIsolation(in: directory)
        let file = directory.appendingPathComponent("runs.json")
        let history = HakoShortcutHistory(fileURL: file)
        let registry = HakoShortcutRegistry(history: history)
        var successfulCalls = 0, failedCalls = 0
        var executionModes: [Bool] = []
        var expiredSink: HakoExecutionDiagnostics.Sink?
        registry.register("A") { successfulCalls += 1; return "ok" }
        var skipCalls = 0
        registry.register("Skip") { skipCalls += 1; throw HakoShortcutSkip(reason: "not Sunday") }
        registry.register("B") {
            executionModes.append(HakoShortcutExecution.isManual)
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
        precondition(history.runs[0].status == .failed && history.runs[0].steps.count == 3)
        do { _ = try await registry.retryRun(id); preconditionFailure("Retry failure was ignored") }
        catch {}
        precondition(history.runs[0].status == .failed && successfulCalls == 1 && failedCalls == 2)
        _ = try await registry.retryRun(id)
        precondition(history.runs.count == 1 && history.runs[0].id == id)
        precondition(history.runs[0].status == .succeeded && history.runs[0].finishedAt != nil)
        precondition(history.runs[0].steps.count == 3 && history.runs[0].steps.allSatisfy { [.succeeded, .skipped].contains($0.status) })
        precondition(successfulCalls == 1 && failedCalls == 3, "Successful steps must not run again")
        precondition(executionModes == [false, true, true], "Explicit retries must run as manual executions")
        precondition(!HakoShortcutExecution.isManual, "Execution mode leaked outside its callback")
        let step = history.runs[0].steps.first { $0.name == "B" }!
        precondition(step.attempts == 3 && step.message == "recovered")
        precondition(firstEvents.allSatisfy { id in step.events!.contains { $0.id == id } }, "Retry erased previous failure logs")
        precondition(!step.events!.contains { $0.stage == "过期任务日志" }, "Late logs contaminated a retry")
        let persisted = try Data(contentsOf: file)
        precondition(!String(decoding: persisted, as: UTF8.self).contains("fake-secret-456"))
        let restored = HakoShortcutHistory(fileURL: file)
        precondition(restored.runs[0].status == .succeeded && restored.runs[0].steps.count == 3)
        precondition(restored.runs[0].steps.first { $0.name == "B" }?.events?.count == step.events?.count)
        do { _ = try await registry.retryRun(id); preconditionFailure("Successful run was retried") }
        catch {}
        precondition(failedCalls == 3)
        precondition(skipCalls == 1, "Skipped step was retried with failed steps")
        _ = try await registry.runCallbacks(title: "Only skipped", names: ["Skip"])
        precondition(skipCalls == 2 && successfulCalls == 1 && failedCalls == 3)
        precondition(history.runs[0].status == .skipped && history.runs[0].steps[0].status == .skipped)
        var manualModes: [Bool] = []
        registry.register("Manual") {
            await Task.yield()
            manualModes.append(HakoShortcutExecution.isManual)
            return "ok"
        }
        _ = try await registry.runCallbacks(title: "Manual backup", names: ["Manual"], manual: true)
        _ = try await registry.runCallbacks(title: "Scheduled backup", names: ["Manual"])
        precondition(manualModes == [true, false], "Manual execution affected a later scheduled run")
        var reported: [Int] = []
        _ = try await registry.runCallbacks(title: "Progress", names: ["Manual"], progress: { task, stage, completed, total in
            precondition(task == "Manual" && !stage.isEmpty && total == 1)
            reported.append(completed)
        })
        precondition(reported.first == 0 && reported.last == 1, "Intent progress did not follow real task completion")
        let merged = HakoExecutionLogRow.merging(history.runs[0].steps[0].events ?? [])
        precondition(merged.filter { $0.stage == "执行子任务" }.count == 1)
        precondition(merged.first { $0.stage == "执行子任务" }?.finishedAt != nil)
        registry.register("Cancellation") { throw CancellationError() }
        let cancellation = HakoExecutionCancellation()
        cancellation.record("用户取消了快捷指令。")
        do {
            _ = try await HakoExecutionDiagnostics.cancellation.withValue(cancellation) {
                try await registry.runCallbacks(title: "User cancellation", names: ["Cancellation"])
            }
            preconditionFailure("Cancellation was swallowed")
        } catch is CancellationError { }
        precondition(history.runs[0].status == .cancelled && history.runs[0].steps[0].message?.contains("用户取消") == true)
        cancellation.record("系统结束后台执行：超过允许的执行时间。")
        history.recordCancellation(cancellation)
        history.recordCancellation(cancellation)
        precondition(history.runs[0].steps[0].events?.filter { $0.id == cancellation.id }.count == 1)
        precondition(history.runs[0].steps[0].message?.contains("系统结束后台执行") == true, "A late system cancellation reason was lost")
        let oldAttempt = cancellation.attempt!.id
        history.recordStep("Cancellation", status: .running, runID: cancellation.runID!)
        history.recordCancellation(cancellation)
        precondition(history.runs[0].steps[0].attemptID != oldAttempt && history.runs[0].steps[0].message == nil,
                     "Cancellation from an older attempt contaminated a retry")
        history.recordStep("Cancellation", status: .cancelled, runID: cancellation.runID!)
        var firstCalls = 0, cancelledCalls = 0, pendingCalls = 0
        registry.register("Retry A") { firstCalls += 1; return "done" }
        registry.register("Retry B") {
            cancelledCalls += 1
            if cancelledCalls == 1 { throw CancellationError() }
            precondition(HakoShortcutExecution.isManual)
            return "recovered"
        }
        registry.register("Retry C") { pendingCalls += 1; return "started after retry" }
        do {
            _ = try await registry.runCallbacks(title: "Cancelled child with remaining work", names: ["Retry A", "Retry B", "Retry C"])
            preconditionFailure("Cancelled task completed")
        } catch let error as HakoError { precondition(error.message.contains("Retry B")) }
        let cancelledID = history.runs[0].id
        precondition(history.runs[0].steps.map(\.status) == [.succeeded, .cancelled, .succeeded])
        _ = try await registry.retryRun(cancelledID)
        precondition(history.runs[0].id == cancelledID && history.runs[0].status == .succeeded)
        precondition(firstCalls == 1 && cancelledCalls == 2 && pendingCalls == 1, "Retry repeated another child's successful work")
        do { _ = try await registry.runCallbacks(title: "Unknown", names: ["removed"]); preconditionFailure("Unknown selection accepted") }
        catch {}
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
        let retryInterrupted = HakoShortcutRegistry(history: interrupted)
        retryInterrupted.register("bounded") { "recovered after restart" }
        _ = try await retryInterrupted.retryRun(interrupted.runs[0].id)
        precondition(interrupted.runs[0].status == .succeeded && interrupted.runs[0].steps[0].attempts == 2)
        print("PASS: isolated child failures and cancellations, whole-run cancellation, progress, persistent retries and preserved successful steps")
    }

    @MainActor private static func checkFailureIsolation(in directory: URL) async throws {
        let history = HakoShortcutHistory(fileURL: directory.appendingPathComponent("isolation.json"))
        let registry = HakoShortcutRegistry(history: history)
        var afterFailure = 0
        registry.register("Failure A") { throw HakoError(message: "ordinary failure") }
        registry.register("Failure B") { afterFailure += 1; return "backup completed" }
        do {
            _ = try await registry.runCallbacks(title: "Ordinary failure", names: ["Failure A", "Failure B"])
            preconditionFailure("An ordinary failure was reported as success")
        } catch let error as HakoError {
            precondition(error.message.contains("ordinary failure") && error.message.contains("backup completed"))
        }
        precondition(afterFailure == 1 && history.runs[0].steps.map(\.status) == [.failed, .succeeded])

        var cancelledCalls = 0, backupCalls = 0
        registry.register("Local A") {
            cancelledCalls += 1
            if cancelledCalls == 1 { throw CancellationError() }
            return "recovered"
        }
        registry.register("Local B") { backupCalls += 1; return "backup completed" }
        do {
            _ = try await registry.runCallbacks(title: "Child cancellation", names: ["Local A", "Local B"])
            preconditionFailure("A cancelled child was reported as success")
        } catch let error as HakoError {
            precondition(error.message.contains("Local A") && error.message.contains("backup completed"))
        } catch { preconditionFailure("A single child cancellation stopped the whole run: \(error)") }
        precondition(backupCalls == 1 && history.runs[0].status == .failed)
        precondition(history.runs[0].steps.map(\.status) == [.cancelled, .succeeded])
        _ = try await registry.retryRun(history.runs[0].id)
        precondition(cancelledCalls == 2 && backupCalls == 1, "Retry repeated an already completed backup")

        var isolatedBackup = 0
        registry.register("Self A") {
            withUnsafeCurrentTask { $0?.cancel() }
            throw URLError(.cancelled)
        }
        registry.register("Self B") {
            precondition(!Task.isCancelled, "Cancellation leaked from another child")
            isolatedBackup += 1
            return "backup completed"
        }
        var progress: [Int] = []
        do {
            _ = try await registry.runCallbacks(title: "Self-cancelled child", names: ["Self A", "Self B"], progress: { _, _, done, _ in progress.append(done) })
            preconditionFailure("A self-cancelled child was reported as success")
        } catch is HakoError { }
        precondition(!Task.isCancelled && isolatedBackup == 1)
        precondition(history.runs[0].steps.map(\.status) == [.cancelled, .succeeded])
        precondition(progress.last == 2, "Progress stopped at an isolated child cancellation")

        var childStarted = false, childSawCancellation = false, laterCalls = 0
        registry.register("Whole A") {
            childStarted = true
            do { try await Task.sleep(for: .seconds(60)) }
            catch { childSawCancellation = Task.isCancelled; throw error }
            return "unexpected"
        }
        registry.register("Whole B") { laterCalls += 1; return "unexpected" }
        let whole = Task { @MainActor in
            try await registry.runCallbacks(title: "Whole run cancellation", names: ["Whole A", "Whole B"])
        }
        while !childStarted { await Task.yield() }
        whole.cancel()
        do { _ = try await whole.value; preconditionFailure("Whole-run cancellation was swallowed") }
        catch is CancellationError { }
        precondition(childSawCancellation && laterCalls == 0)
        precondition(history.runs[0].status == .cancelled && history.runs[0].steps.map(\.status) == [.cancelled, .pending])
    }
}
