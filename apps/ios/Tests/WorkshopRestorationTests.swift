import Foundation

@main struct WorkshopRestorationTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workshop-restoration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("account.json")
        let agent = WorkshopAgent(id: "computer", name: "Computer", online: true, protocolVersion: 1)
        let app = WorkshopApplication(id: "project", name: "Project", path: "/project")
        var preferences = WorkshopPreferences()
        preferences.agentId = agent.id; preferences.applicationId = app.id
        let sessions = (0..<5_000).map {
            WorkshopSession(id: UUID().uuidString, title: "Session \($0)", applicationId: app.id, cwd: app.path,
                            preview: String(repeating: "cached message ", count: 50), updatedAt: Int64($0), state: "completed", operationId: nil)
        }
        let snapshot = WorkshopListSnapshot(agents: [agent], catalogs: [agent.id: WorkshopCachedCatalog(
            catalog: WorkshopCatalog(applications: [app], sessions: sessions, nextCursor: "older"), savedAt: .now)])
        let lists = root.appendingPathComponent("account-lists.json")
        try JSONEncoder().encode(snapshot).write(to: lists)
        let promptFile = file.deletingPathExtension().appendingPathExtension("instructions.txt")
        try "Keep the existing project instructions.".write(to: promptFile, atomically: true, encoding: .utf8)

        // The old entry path used queue.sync and blocked every UIKit event here.
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let disk = WorkshopPersistence { bytes, target in
            entered.signal()
            precondition(release.wait(timeout: .now() + 5) == .success, "Restoration blocked the UI actor")
            try bytes.write(to: target, options: .atomic)
        }
        let pendingPreferences = preferences
        let writer = Task.detached { try disk.write(pendingPreferences, to: file) }
        let started = await Task.detached { entered.wait(timeout: .now() + 2) == .success }.value
        precondition(started)
        let restoration = Task { @MainActor in
            let state = await WorkshopRestoredState.load(at: file, disk: disk)
            completed.signal()
            return state
        }
        await Task.yield()
        // Navigation and other controls can run while the cache writer is stuck.
        let heartbeat = Task { @MainActor in true }
        let responsive = await heartbeat.value
        precondition(responsive)
        let finishedEarly = await Task.detached { completed.wait(timeout: .now() + 0.1) == .success }.value
        precondition(!finishedEarly, "Restoration did not preserve ordering with pending state writes")
        release.signal()
        try await writer.value
        let restored = await restoration.value
        precondition(restored.preferences == preferences)
        precondition(restored.lists == snapshot && restored.lists?.catalogs[agent.id]?.catalog.sessions.count == 5_000)
        precondition(restored.systemPrompt == "Keep the existing project instructions." && restored.systemPromptIssue == nil)
        precondition(restored.queuedSends.isEmpty && restored.computers == nil)

        try String(repeating: "x", count: WorkshopSystemPrompt.maximumLength + 1).write(to: promptFile, atomically: true, encoding: .utf8)
        let invalid = await WorkshopRestoredState.load(at: file, disk: WorkshopPersistence())
        precondition(invalid.systemPrompt == WorkshopSystemPrompt.defaultText && invalid.systemPromptIssue != nil)
        precondition(invalid.lists == snapshot, "A bad prompt must not discard the session cache")
        let absent = await WorkshopRestoredState.load(at: root.appendingPathComponent("other.json"), disk: WorkshopPersistence())
        precondition(absent.preferences == WorkshopPreferences() && absent.lists == nil && absent.systemPromptIssue == nil)
        print("PASS: 5,000 cached sessions restored off the UI actor, stalled writes preserve navigation responsiveness and ordering, prompt errors stay isolated")
    }
}
