import Foundation

@main struct HakoDiagnosticStoreTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Diagnostics")
        let store = HakoDiagnosticStore(directory: folder, capacity: 3)
        for index in 0..<110 { store.breadcrumb("step-\(index)", detail: "token=private-token") }
        let id = UUID()
        store.record(.localHang, detail: "未恢复", id: id, time: Date(timeIntervalSince1970: 10))
        let initial = await store.snapshot()
        precondition(initial.reports.count == 1 && initial.breadcrumbs.count == 100 && initial.issue == nil)
        precondition(initial.reports[0].breadcrumbs.count == 100)
        precondition(!initial.reports[0].entry.text.contains("private-token"))
        // Immediate report persistence, without needing a recovered main thread or flush.
        let earlyRestart = await HakoDiagnosticStore(directory: folder).snapshot()
        precondition(earlyRestart.reports.first?.detail == "未恢复")
        store.record(.localHang, detail: "已恢复", id: id, time: Date(timeIntervalSince1970: 30))
        let updated = await store.snapshot()
        precondition(updated.reports.count == 1 && updated.reports[0].time == Date(timeIntervalSince1970: 10))
        precondition(updated.reports[0].detail == "已恢复")
        store.record(.crash, detail: "系统崩溃", time: Date(timeIntervalSince1970: 20), fingerprint: "crash-one")
        store.record(.crash, detail: "重复系统崩溃", fingerprint: "crash-one")
        let dedup = await store.snapshot()
        precondition(dedup.reports.count == 2)
        store.flush()
        let restart = HakoDiagnosticStore(directory: folder, capacity: 3)
        restart.record(.crash, detail: "重新启动再次下发", fingerprint: "crash-one")
        let restarted = await restart.snapshot()
        precondition(restarted.reports.count == 2 && restarted.breadcrumbs.count == 100)

        // A flood of unrelated rolling logs does not evict diagnostics, or vice versa.
        let logs = HakoLogStore(fileURL: root.appendingPathComponent("events.json"))
        for index in 0..<1_100 { logs.append(source: .hako, level: .info, message: "ordinary-\(index)") }
        logs.flush()
        precondition(logs.snapshot().entries.count == HakoLogStore.capacity)
        let independent = await restart.snapshot()
        precondition(independent.reports.count == 2)
        logs.clear()
        let afterLogClear = await restart.snapshot()
        precondition(afterLogClear.reports.count == 2)
        logs.append(source: .hako, level: .info, message: "preserve-me"); logs.flush()

        restart.record(.systemHang, detail: "第三条", time: Date(timeIntervalSince1970: 40))
        restart.record(.presentation, detail: "第四条", time: Date(timeIntervalSince1970: 50))
        let trimmed = await restart.snapshot()
        precondition(trimmed.reports.count == 3 && !trimmed.reports.contains { $0.id == id })
        let trimmedRestart = await HakoDiagnosticStore(directory: folder).snapshot()
        precondition(trimmedRestart.reports.count == 3)
        await restart.clear()
        let clearedRestart = await HakoDiagnosticStore(directory: folder).snapshot()
        precondition(clearedRestart.reports.isEmpty)
        precondition(logs.snapshot().entries.first?.message == "preserve-me")

        let limitedFolder = root.appendingPathComponent("limited")
        let limited = HakoDiagnosticStore(directory: limitedFolder, byteLimit: 4_096)
        for index in 0..<8 { limited.record(.crash, detail: String(repeating: "x", count: 2_000), time: Date(timeIntervalSince1970: Double(index))) }
        let budget = await limited.snapshot()
        precondition(budget.reports.count == 1)
        let files = try FileManager.default.contentsOfDirectory(at: limitedFolder, includingPropertiesForKeys: [.fileSizeKey])
        let bytes = try files.filter { $0.lastPathComponent.hasSuffix(".report.json") }.reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        precondition(bytes <= 4_096)

        let corrupt = folder.appendingPathComponent(UUID().uuidString + ".report.json")
        try Data("corrupt".utf8).write(to: corrupt)
        let damaged = await HakoDiagnosticStore(directory: folder).snapshot()
        precondition(damaged.issue != nil)
        let blockedStore = HakoDiagnosticStore(directory: corrupt.appendingPathComponent("invalid"))
        blockedStore.record(.localHang, detail: "保留内存")
        let blocked = await blockedStore.snapshot()
        precondition(blocked.issue != nil && blocked.reports.count == 1)
        let boundedFailure = HakoDiagnosticStore(directory: nil, capacity: 3)
        for index in 0..<20 { boundedFailure.record(.localHang, detail: "failure-\(index)") }
        let failedRetention = await boundedFailure.snapshot()
        precondition(failedRetention.reports.count == 3 && failedRetention.issue != nil)
        print("Independent diagnostic persistence, recovery updates, durable dedup, privacy, retention, clear and failure checks passed")
    }
}
