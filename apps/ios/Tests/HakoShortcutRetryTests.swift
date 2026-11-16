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
        registry.register("A") { successfulCalls += 1; return "ok" }
        registry.register("B") {
            failedCalls += 1
            precondition(history.runs[0].status == .running)
            do { _ = try await registry.retryRun(history.runs[0].id); preconditionFailure("Concurrent retry accepted") }
            catch {}
            if failedCalls < 3 { throw HakoError(message: "offline") }
            return "recovered"
        }
        do { _ = try await registry.runCallbacks(title: "同步 Hako 数据"); preconditionFailure("Failure was ignored") }
        catch {}
        let id = history.runs[0].id
        precondition(history.runs[0].status == .failed && history.runs[0].steps.count == 2)
        do { _ = try await registry.retryRun(id); preconditionFailure("Retry failure was ignored") }
        catch {}
        precondition(history.runs[0].status == .failed && successfulCalls == 1 && failedCalls == 2)
        _ = try await registry.retryRun(id)
        precondition(history.runs.count == 1 && history.runs[0].id == id)
        precondition(history.runs[0].status == .succeeded && history.runs[0].finishedAt != nil)
        precondition(history.runs[0].steps.count == 2 && history.runs[0].steps.allSatisfy { $0.status == .succeeded })
        precondition(successfulCalls == 1 && failedCalls == 3, "Successful steps must not run again")
        let restored = HakoShortcutHistory(fileURL: file)
        precondition(restored.runs[0].status == .succeeded && restored.runs[0].steps.count == 2)
        do { _ = try await registry.retryRun(id); preconditionFailure("Successful run was retried") }
        catch {}
        precondition(failedCalls == 3)
        let unavailable = history.start("unavailable")
        history.recordStep("removed", status: .failed, runID: unavailable)
        history.finish(unavailable, status: .failed)
        do { _ = try await registry.retryRun(unavailable); preconditionFailure("Unavailable callback accepted") }
        catch {}
        precondition(history.runs[0].status == .failed)
        print("PASS: shortcut retry updates and persists the original record, preserves successful steps, rejects duplicate and unavailable tasks")
    }
}
