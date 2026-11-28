import Foundation

// View construction must never wait for the state writer, disk reads or JSON
// decoding. Restore one account snapshot before starting its live catalog reads.
struct WorkshopRestoredState: Sendable {
    let preferences: WorkshopPreferences
    let queuedSends: [WorkshopQueuedSend]
    let readState: WorkshopReadState
    let lists: WorkshopListSnapshot?
    let computers: [WorkshopAgent]?
    let systemPrompt: String
    let systemPromptIssue: String?

    static func load(at file: URL, disk: WorkshopPersistence) async -> Self {
        let preferences = (try? await disk.readAsync(WorkshopPreferences.self, from: file)) ?? WorkshopPreferences()
        let queue = file.deletingPathExtension().appendingPathExtension("queue.json")
        let queuedSends = (try? await disk.readAsync([WorkshopQueuedSend].self, from: queue)) ?? []
        let read = file.deletingPathExtension().appendingPathExtension("read.json")
        let readState = (try? await disk.readAsync(WorkshopReadState.self, from: read)) ?? WorkshopReadState()
        let lists = file.deletingLastPathComponent().appendingPathComponent(file.deletingPathExtension().lastPathComponent + "-lists.json")
        let snapshot = try? await disk.readAsync(WorkshopListSnapshot.self, from: lists)
        let computers = file.deletingPathExtension().appendingPathExtension("workshop-computers.json")
        let inventory = try? await disk.readAsync([WorkshopAgent].self, from: computers)
        let promptFile = file.deletingPathExtension().appendingPathExtension("instructions.txt")
        let (prompt, issue) = await Task.detached(priority: .utility) { () -> (String, String?) in
            guard FileManager.default.fileExists(atPath: promptFile.path) else { return (WorkshopSystemPrompt.defaultText, nil) }
            do {
                let text = try String(contentsOf: promptFile, encoding: .utf8)
                guard WorkshopSystemPrompt.valid(text) else { throw CocoaError(.coderReadCorrupt) }
                return (text, nil)
            } catch { return (WorkshopSystemPrompt.defaultText, "无法读取已保存的系统提示词，请在代码工坊设置中检查后重新保存。") }
        }.value
        return Self(preferences: preferences, queuedSends: queuedSends, readState: readState,
                    lists: snapshot, computers: inventory, systemPrompt: prompt, systemPromptIssue: issue)
    }
}
