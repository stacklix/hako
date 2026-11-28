import Foundation

@main
struct AssistantConversationHistoryTests {
    struct Conversation: Codable, Equatable {
        var messages: [String]
        let image: Data
        let confirmed: Bool
    }
    struct Tool: Codable, Equatable { let command: String; let state: String }

    static func check(_ condition: Bool, _ message: String) { precondition(condition, message) }

    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let current = directory.appendingPathComponent("account-a.plist")
        let other = directory.appendingPathComponent("account-b.plist")
        let files = AssistantConversationFiles<Conversation, Tool>(url: current)
        let history = AssistantConversationHistory()
        check(try await history.list(current: current).isEmpty, "A fresh account starts with no history")

        let photo = Data([0x89, 0x50, 0x4e, 0x47, 0x01])
        let first = Conversation(messages: ["买入腾讯控股", "已记账"], image: photo, confirmed: true)
        let tools = [Tool(command: "inspect_ledger", state: "completed")]
        let draft = AssistantComposerDraft(text: "下一笔还没发送", attachments: [.init(photoIdentifier: nil, data: photo)])
        try files.save(first); try files.saveToolCalls(tools); try files.saveComposerDraft(draft)
        let firstEntry = try await history.save(current: current, title: "买入腾讯控股", preview: "已记账")
        let firstSnapshot = try await history.load(firstEntry.id, current: current)
        try firstSnapshot.validate(conversation: Conversation.self, tool: Tool.self)
        check(try PropertyListDecoder().decode(Conversation.self, from: firstSnapshot.conversation) == first,
              "The archived receipt and image must retain their original values")
        check(try PropertyListDecoder().decode([Tool].self, from: firstSnapshot.tools!) == tools, "Tool records are retained")
        check(try PropertyListDecoder().decode(AssistantComposerDraft.self, from: firstSnapshot.draft!) == draft,
              "Unsent drafts and their photos are retained")
        check(try await history.isActive(firstEntry.id, current: current), "The active identity is persisted")

        let updated = Conversation(messages: first.messages + ["查询收益"], image: photo, confirmed: true)
        try files.save(updated)
        let updatedEntry = try await history.save(current: current, title: "买入腾讯控股", preview: "查询收益")
        check(updatedEntry.id == firstEntry.id, "Updating the same conversation must not duplicate its history row")
        check(try await history.list(current: current).count == 1, "Only one history row for an updated conversation")

        try await history.reset(current: current)
        check(try files.load() == nil && files.loadToolCalls().isEmpty && files.loadComposerDraft().isEmpty,
              "Starting a new conversation clears only active files")
        check(try await history.list(current: current).count == 1, "Starting a new conversation preserves history")
        let second = Conversation(messages: ["查询本月交易"], image: Data(), confirmed: false)
        try files.save(second)
        let secondEntry = try await history.save(current: current, title: "查询本月交易", preview: "查看汇总")
        check(secondEntry.id != firstEntry.id, "A new conversation needs a distinct identity")

        let reopened = AssistantConversationHistory()
        let old = try await reopened.load(firstEntry.id, current: current)
        try await reopened.activate(old, current: current)
        check(try files.load() == updated, "A process restart and history switch restore the full conversation")
        check(try files.loadToolCalls() == tools && files.loadComposerDraft() == draft, "Switching restores the matching tools and draft")
        check(try await reopened.isActive(firstEntry.id, current: current), "Continuing history updates that conversation's identity")
        let secondSnapshot = try await reopened.load(secondEntry.id, current: current)
        try await reopened.activate(secondSnapshot, current: current)
        check(try files.load() == second && files.loadToolCalls().isEmpty && files.loadComposerDraft().isEmpty,
              "A conversation without attachments must not inherit another conversation's tools or draft")

        check(try await reopened.list(current: other).isEmpty, "Accounts and panel connections have separate history roots")
        do { _ = try await reopened.load(firstEntry.id, current: other); fatalError("Cross-account history must be rejected") }
        catch { }

        let blocked = directory.appendingPathComponent("blocked.plist")
        try Data("keep current conversation".utf8).write(to: blocked)
        try Data("occupied history path".utf8).write(to: blocked.appendingPathExtension("history"))
        do { _ = try await reopened.save(current: blocked, title: "失败测试", preview: ""); fatalError("Disk failure must be reported") }
        catch { }
        check(try Data(contentsOf: blocked) == Data("keep current conversation".utf8), "Archive failure must leave the active conversation intact")
        check(!FileManager.default.fileExists(atPath: blocked.appendingPathExtension("identity").path), "Failed archives do not publish an active identity")
        let corrupt = AssistantConversationHistory.Snapshot(entry: firstEntry, conversation: Data("bad bytes".utf8), tools: nil, draft: nil)
        do { try corrupt.validate(conversation: Conversation.self, tool: Tool.self); fatalError("Corrupt history must be rejected before activating") }
        catch { }
        check(try files.load() == second, "Rejected history leaves the active conversation unchanged")
        print("PASS: local history restart, photos, tools, unsent drafts, stable identities, new/switch, scope isolation and failed-save preservation")
    }
}
