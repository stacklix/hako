import Foundation

// The registry contract is tested independently of application services.
@MainActor enum HakoApplications {
    static func registerShortcuts(in registry: HakoShortcutRegistry) {}
}

@main struct HakoShortcutRetryTests {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await checkScheduleOverrides(in: directory)
        try await checkFailureIsolation(in: directory)
        try await checkOperationProgress(in: directory)
        try await checkGroupedExecution(in: directory)
        try await checkParallelCancellation(in: directory)
        try await checkInvalidRegistrations()
        let file = directory.appendingPathComponent("runs.json")
        let history = HakoShortcutHistory(fileURL: file)
        let registry = HakoShortcutRegistry(history: history)
        var successfulCalls = 0, failedCalls = 0
        var executionModes: [Bool] = []
        var expiredSink: HakoExecutionDiagnostics.Sink?
        registry.register("A", group: "serial", order: 1) { successfulCalls += 1; return "ok" }
        var skipCalls = 0
        registry.register("Skip", group: "serial", order: 3) { skipCalls += 1; throw HakoShortcutSkip(reason: "not Sunday") }
        registry.register("B", group: "serial", order: 2) {
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
        precondition(registry.registeredTaskNames == ["A", "B", "Skip"])
        precondition(successfulCalls == 0 && failedCalls == 0 && skipCalls == 0,
                     "Reading the task catalog must not execute callbacks")
        do { _ = try await registry.runCallbacks(title: "同步 Hako 数据"); preconditionFailure("Failure was ignored") }
        catch {}
        let id = history.runs[0].id
        precondition(history.runs[0].triggerSource == .shortcuts)
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
        precondition(history.runs[0].triggerSource == .shortcuts, "Retry must retain the original trigger source")
        precondition(history.runs[0].lastRetrySource == .manual)
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
        precondition(restored.runs[0].triggerSource == .shortcuts && restored.runs[0].lastRetrySource == .manual)
        precondition(step.events?.contains { $0.stage == "触发来源" && $0.detail == "App 内触发（重试）" } == true)
        precondition(restored.runs[0].steps.first { $0.name == "B" }?.events?.count == step.events?.count)
        do { _ = try await registry.retryRun(id); preconditionFailure("Successful run was retried") }
        catch {}
        precondition(failedCalls == 3)
        precondition(skipCalls == 1, "Skipped step was retried with failed steps")
        _ = try await registry.runCallbacks(title: "Only skipped", names: ["Skip"])
        precondition(skipCalls == 2 && successfulCalls == 1 && failedCalls == 3)
        precondition(history.runs[0].status == .skipped && history.runs[0].steps[0].status == .skipped)
        var manualModes: [Bool] = []
        registry.register("Manual", group: "serial", order: 13) {
            await Task.yield()
            manualModes.append(HakoShortcutExecution.isManual)
            return "ok"
        }
        _ = try await registry.runCallbacks(title: "Manual backup", names: ["Manual"], manual: true)
        precondition(history.runs[0].triggerSource == .manual)
        _ = try await registry.runCallbacks(title: "Scheduled backup", names: ["Manual"])
        precondition(history.runs[0].triggerSource == .shortcuts, "Do not assume external shortcuts are automatic")
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
        let cancellation = HakoExecutionCancellation()
        registry.register("Cancellation", group: "serial", order: 14) {
            cancellation.record("用户取消了快捷指令。")
            throw CancellationError()
        }
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
        let oldAttempt = cancellation.attempts["Cancellation"]!
        history.recordStep("Cancellation", status: .running, runID: cancellation.runID!)
        history.recordCancellation(cancellation)
        precondition(history.runs[0].steps[0].attemptID != oldAttempt && history.runs[0].steps[0].message == nil,
                     "Cancellation from an older attempt contaminated a retry")
        history.recordStep("Cancellation", status: .cancelled, runID: cancellation.runID!)
        var firstCalls = 0, cancelledCalls = 0, pendingCalls = 0
        registry.register("Retry A", group: "serial", order: 15) { firstCalls += 1; return "done" }
        registry.register("Retry B", group: "serial", order: 16) {
            cancelledCalls += 1
            if cancelledCalls == 1 { throw CancellationError() }
            precondition(HakoShortcutExecution.isManual)
            return "recovered"
        }
        registry.register("Retry C", group: "serial", order: 17) { pendingCalls += 1; return "started after retry" }
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
        retryInterrupted.register("bounded", group: "serial", order: 18) { "recovered after restart" }
        _ = try await retryInterrupted.retryRun(interrupted.runs[0].id)
        precondition(interrupted.runs[0].status == .succeeded && interrupted.runs[0].steps[0].attempts == 2)
        print("PASS: parallel groups, ordered children, validation, isolated cancellation/progress, scheduled retries and persistent history")
    }

    @MainActor private static func checkScheduleOverrides(in directory: URL) async throws {
        let history = HakoShortcutHistory(fileURL: directory.appendingPathComponent("schedule.json"))
        let registry = HakoShortcutRegistry(history: history)
        var executions = 0
        registry.register("Scheduled", group: "serial", order: 19) {
            guard HakoShortcutExecution.isManual && HakoShortcutExecution.ignoresSchedule else {
                throw HakoShortcutSkip(reason: "not due")
            }
            executions += 1
            if executions > 1 { throw HakoError(message: "upload failed") }
            return "done"
        }
        // A system cancellation can leave this child pending. Retrying that
        // shortcut must check the schedule before doing any business work.
        let pending = history.start("External shortcut", steps: ["Scheduled"], source: .shortcuts)
        history.finish(pending, status: .cancelled)
        _ = try await registry.retryRun(pending)
        precondition(executions == 0 && history.runs[0].status == .skipped)
        precondition(history.runs[0].triggerSource == .shortcuts && history.runs[0].lastRetrySource == .manual)
        _ = try await registry.runCallbacks(title: "In-app sync", manual: true)
        precondition(executions == 0 && history.runs[0].status == .skipped)
        _ = try await registry.runCallbacks(title: "Single manual action", names: ["Scheduled"], manual: true, ignoresSchedule: true)
        precondition(executions == 1 && history.runs[0].status == .succeeded)
        do {
            _ = try await registry.runCallbacks(title: "Failed manual action", names: ["Scheduled"], manual: true, ignoresSchedule: true)
            preconditionFailure("Failure lost")
        } catch is HakoError {}
        _ = try await registry.retryRun(history.runs[0].id)
        precondition(executions == 2 && history.runs[0].status == .skipped,
                     "History retry must not silently repeat a schedule override")
        _ = try await HakoShortcutExecution.scheduleOverride.withValue(true) {
            try await registry.runCallbacks(title: "Inherited context", manual: true)
        }
        precondition(executions == 2 && !HakoShortcutExecution.ignoresSchedule)
        for manual in [false, true] {
            do {
                _ = try await registry.runCallbacks(title: "Invalid override", names: manual ? nil : ["Scheduled"],
                                                    manual: manual, ignoresSchedule: true)
                preconditionFailure("Override allowed without an explicit single manual action")
            } catch is HakoError {}
        }
        precondition(!history.runs.contains { $0.status == .running })
    }

    @MainActor private static func checkOperationProgress(in directory: URL) async throws {
        let history = HakoShortcutHistory(fileURL: directory.appendingPathComponent("progress.json"))
        let registry = HakoShortcutRegistry(history: history)
        var updates: [(done: Int, total: Int)] = []
        var lateSink: HakoExecutionDiagnostics.Sink?
        registry.register("Collection", group: "serial", order: 20) {
            lateSink = HakoExecutionDiagnostics.sink
            await HakoExecutionDiagnostics.measure("采集资产") {
                for index in 0..<5 {
                    await Task.yield()
                    _ = HakoExecutionDiagnostics.measure("请求 \(index)") { index }
                    precondition(updates.last!.done == index + 1,
                                 "System progress stayed unchanged until the entire child finished")
                    precondition(updates.last!.done < updates.last!.total,
                                 "Progress finished before collection and synchronization finished")
                }
                let done = updates.last!.done
                HakoExecutionDiagnostics.record("等待远端响应")
                precondition(updates.last!.done == done, "Informational events fabricated completed work")
                let event = HakoExecutionEvent(stage: "单次请求", state: .started, detail: "")
                HakoExecutionDiagnostics.sink?(event)
                let finished = HakoExecutionEvent(id: event.id, stage: event.stage, state: .succeeded, detail: "")
                HakoExecutionDiagnostics.sink?(finished)
                HakoExecutionDiagnostics.sink?(finished)
                precondition(updates.last!.done == done + 1, "Duplicate events inflated progress")
            }
            return "saved"
        }
        registry.register("Sync", group: "serial", order: 21) {
            let previous = updates.last!.done
            lateSink?(HakoExecutionEvent(stage: "过期请求", state: .started, detail: ""))
            precondition(updates.last!.done == previous, "Previous child changed the current progress")
            return "uploaded"
        }
        _ = try await registry.runCallbacks(title: "Granular progress", progress: { _, _, done, total in
            updates.append((done, total))
        })
        precondition(updates.first!.done == 0 && updates.last!.done == updates.last!.total)
        precondition(zip(updates, updates.dropFirst()).allSatisfy { $0.done <= $1.done },
                     "Completed operation counts moved backwards")
        let updateCount = updates.count
        lateSink?(HakoExecutionEvent(stage: "过期请求", state: .succeeded, detail: ""))
        precondition(updates.count == updateCount, "Finished runs kept reporting progress")
    }

    @MainActor private static func checkFailureIsolation(in directory: URL) async throws {
        let history = HakoShortcutHistory(fileURL: directory.appendingPathComponent("isolation.json"))
        let registry = HakoShortcutRegistry(history: history)
        var afterFailure = 0
        registry.register("Failure A", group: "serial", order: 22) { throw HakoError(message: "ordinary failure") }
        registry.register("Failure B", group: "serial", order: 23) { afterFailure += 1; return "backup completed" }
        do {
            _ = try await registry.runCallbacks(title: "Ordinary failure", names: ["Failure A", "Failure B"])
            preconditionFailure("An ordinary failure was reported as success")
        } catch let error as HakoError {
            precondition(error.message.contains("ordinary failure") && error.message.contains("backup completed"))
        }
        precondition(afterFailure == 1 && history.runs[0].steps.map(\.status) == [.failed, .succeeded])

        var cancelledCalls = 0, backupCalls = 0
        registry.register("Local A", group: "serial", order: 24) {
            cancelledCalls += 1
            if cancelledCalls == 1 { throw CancellationError() }
            return "recovered"
        }
        registry.register("Local B", group: "serial", order: 25) { backupCalls += 1; return "backup completed" }
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
        registry.register("Self A", group: "serial", order: 26) {
            withUnsafeCurrentTask { $0?.cancel() }
            throw URLError(.cancelled)
        }
        registry.register("Self B", group: "serial", order: 27) {
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
        registry.register("Whole A", group: "serial", order: 28) {
            childStarted = true
            do { try await Task.sleep(for: .seconds(60)) }
            catch { childSawCancellation = Task.isCancelled; throw error }
            return "unexpected"
        }
        registry.register("Whole B", group: "serial", order: 29) { laterCalls += 1; return "unexpected" }
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

    @MainActor private static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            try Task.checkCancellation()
            precondition(ContinuousClock.now < deadline, "Parallel groups stopped making progress")
            await Task.yield()
        }
    }

    @MainActor private static func checkGroupedExecution(in directory: URL) async throws {
        let history = HakoShortcutHistory(fileURL: directory.appendingPathComponent("groups.json"))
        let registry = HakoShortcutRegistry(history: history)
        var started: Set<String> = []
        var updateEnded = false, cryptoEnded = false, backupStarted = false
        var updateCalls = 0, backupCalls = 0, usageCalls = 0, cryptoCalls = 0
        var staleSink: HakoExecutionDiagnostics.Sink?
        var updates: [(done: Int, total: Int)] = []
        // Identical IDs in different child sinks must remain independently counted.
        let requestID = UUID()
        func request(_ state: HakoExecutionEvent.State) -> HakoExecutionEvent {
            HakoExecutionEvent(id: requestID, stage: "真实请求", state: state, detail: "")
        }
        // Register the later child first; sequence must come from order, not name or registration time.
        registry.register("A backup", group: "investment", order: 2) {
            backupCalls += 1
            if backupCalls == 1 {
                precondition(updateEnded && !cryptoEnded, "Backup did not follow its own group immediately")
                let count = updates.count
                staleSink?(HakoExecutionEvent(stage: "过期步骤", state: .info, detail: ""))
                precondition(updates.count == count, "Finished child's sink reported late progress")
            }
            backupStarted = true
            return "backed up"
        }
        registry.register("Z update", group: "investment", order: 1) {
            updateCalls += 1
            if updateCalls > 1 { return "recovered" }
            staleSink = HakoExecutionDiagnostics.sink
            HakoExecutionDiagnostics.sink?(request(.started))
            started.insert("update")
            try await waitUntil { started.count == 3 }
            precondition(history.runs[0].steps.filter { $0.status == .running }.count == 3)
            HakoExecutionDiagnostics.sink?(request(.failed))
            updateEnded = true
            throw HakoError(message: "quote failed")
        }
        registry.register("Crypto", group: "crypto", order: 1) {
            cryptoCalls += 1
            HakoExecutionDiagnostics.sink?(request(.started))
            started.insert("crypto")
            try await waitUntil { started.count == 3 && backupStarted }
            HakoExecutionDiagnostics.sink?(request(.succeeded))
            cryptoEnded = true
            return "collected"
        }
        registry.register("Usage", group: "usage", order: 1) {
            usageCalls += 1
            HakoExecutionDiagnostics.sink?(request(.started))
            started.insert("usage")
            try await waitUntil { started.count == 3 && backupStarted }
            HakoExecutionDiagnostics.sink?(request(.succeeded))
            return "uploaded"
        }
        do {
            _ = try await registry.runCallbacks(title: "Parallel groups", progress: { _, _, done, total in
                updates.append((done, total))
                precondition(done <= total)
            })
            preconditionFailure("Child failure was hidden")
        } catch let error as HakoError {
            precondition(error.message.contains("quote failed") && error.message.contains("backed up"))
        }
        precondition(history.runs[0].steps.map(\.name) == ["Crypto", "Z update", "A backup", "Usage"])
        precondition(history.runs[0].steps.map(\.status) == [.succeeded, .failed, .succeeded, .succeeded])
        precondition(updates.last!.done == 7 && updates.last!.total == 7,
                     "One child finishing erased another child's operations")
        precondition(zip(updates, updates.dropFirst()).allSatisfy { $0.done <= $1.done })
        for step in history.runs[0].steps where step.name != "A backup" {
            precondition(step.events?.filter { $0.id == requestID }.count == 2, "Parallel child logs crossed or disappeared")
            precondition(!step.events!.contains { $0.stage == "过期步骤" })
        }
        _ = try await registry.retryRun(history.runs[0].id)
        precondition(updateCalls == 2 && backupCalls == 1 && usageCalls == 1 && cryptoCalls == 1)
        _ = try await registry.runCallbacks(title: "Standalone backup", names: ["A backup"], manual: true, ignoresSchedule: true)
        precondition(updateCalls == 2 && backupCalls == 2, "Standalone backup implicitly ran its predecessor")
    }

    @MainActor private static func checkParallelCancellation(in directory: URL) async throws {
        let history = HakoShortcutHistory(fileURL: directory.appendingPathComponent("parallel-cancel.json"))
        let registry = HakoShortcutRegistry(history: history)
        let cancellation = HakoExecutionCancellation()
        var started: Set<String> = [], observed: Set<String> = []
        var laterCalls = 0
        for group in ["first", "second"] {
            registry.register(group, group: group, order: 1) {
                started.insert(group)
                do { try await Task.sleep(for: .seconds(60)) }
                catch { if Task.isCancelled { observed.insert(group) }; throw error }
                return "unexpected"
            }
            registry.register(group + " later", group: group, order: 2) { laterCalls += 1; return "unexpected" }
        }
        let whole = Task { @MainActor in
            try await HakoExecutionDiagnostics.cancellation.withValue(cancellation) {
                try await registry.runCallbacks(title: "Parallel cancellation")
            }
        }
        try await waitUntil { started.count == 2 }
        whole.cancel()
        do { _ = try await whole.value; preconditionFailure("Global cancellation was lost") }
        catch is CancellationError {}
        precondition(observed.count == 2 && laterCalls == 0)
        precondition(history.runs[0].status == .cancelled)
        precondition(history.runs[0].steps.map(\.status) == [.cancelled, .pending, .cancelled, .pending])
        // The system reason may arrive after all group tasks have unwound.
        cancellation.record("system timeout")
        history.recordCancellation(cancellation)
        history.recordCancellation(cancellation)
        for step in history.runs[0].steps where step.status == .cancelled {
            precondition(step.message == "system timeout")
            precondition(step.events?.filter { $0.id == cancellation.id }.count == 1)
        }
        precondition(history.runs[0].steps.filter { $0.status == .pending }.allSatisfy { $0.events == nil })
        let old = cancellation.attempts
        for group in ["first", "second"] { history.recordStep(group, status: .running, runID: history.runs[0].id) }
        history.recordCancellation(cancellation)
        precondition(history.runs[0].steps.filter { $0.status == .running }.allSatisfy {
            $0.attemptID != old[$0.name] && $0.message == nil
        }, "Old cancellation contaminated retried parallel tasks")
    }

    @MainActor private static func checkInvalidRegistrations() async throws {
        for kind in 0..<4 {
            let history = HakoShortcutHistory(fileURL: nil)
            let registry = HakoShortcutRegistry(history: history)
            var calls = 0
            registry.register("A", group: "group", order: 1) { calls += 1; return "unexpected" }
            switch kind {
            case 0: registry.register("B", group: "group", order: 1) { "duplicate order" }
            case 1: registry.register("A", group: "other", order: 1) { "duplicate name" }
            case 2: registry.register("B", group: " ", order: 1) { "empty group" }
            default: registry.register("B", group: "group", order: 0) { "invalid order" }
            }
            do {
                _ = try await registry.runCallbacks(title: "Invalid registrations")
                preconditionFailure("Invalid registration ran")
            } catch is HakoError {}
            precondition(calls == 0 && history.runs.isEmpty, "Invalid registration started a partial run")
        }
    }
}
