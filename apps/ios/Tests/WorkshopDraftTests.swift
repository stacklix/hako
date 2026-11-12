import Foundation

@main struct WorkshopDraftTests {
    static func expect(_ expected: WorkshopComposerDraft?, at file: URL, _ message: String = "Saved draft mismatch") throws {
        let actual = try WorkshopDraftDisk.read(file)
        precondition(actual == expected, message)
    }

    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hako-drafts-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.json")
        let second = directory.appendingPathComponent("second.json")
        try expect(nil, at: first)

        let input = WorkshopDraftInput(text: "  未发送的输入\n`code` 👋\n", imageIds: ["photo-one"])
        let draft = WorkshopComposerDraft(input: input)
        precondition(draft.hasUnsentInput, "Unsent text and attachments must mark the conversation as a draft")
        try WorkshopDraftDisk.write(draft, to: first)
        // A fresh read represents another process opening the conversation.
        let restored = try WorkshopDraftDisk.read(first)
        precondition(restored == draft, "Restarting must preserve exact whitespace, Unicode and attachments")
        precondition(!draft.matchesSentMessage(input.text.trimmingCharacters(in: .whitespacesAndNewlines),
            imageIds: input.imageIds, id: "request"), "Polling an old message must not clear a new draft with the same text")

        var sending = draft
        sending.sendingMessageID = "request"
        precondition(!sending.hasUnsentInput, "Submitted input must yield to the running state")
        try WorkshopDraftDisk.write(sending, to: first)
        let pending = try WorkshopDraftDisk.read(first)!
        precondition(pending.matchesSentMessage("未发送的输入\n`code` 👋", imageIds: ["photo-one"], id: "request"))
        precondition(!pending.matchesSentMessage("未发送的输入\n`code` 👋", imageIds: [], id: "request"))
        precondition(!pending.matchesSentMessage("未发送的输入\n`code` 👋", imageIds: ["photo-one"], id: "other-request"))

        let editing = WorkshopComposerDraft(input: WorkshopDraftInput(text: "修改后的排队消息", imageIds: []),
            editingMessageID: "queued", originalInput: input)
        try WorkshopDraftDisk.write(editing, to: second)
        try expect(editing, at: second, "Editing must retain both the edit and the original input")
        try expect(sending, at: first, "Another conversation must not overwrite the first draft")

        let empty = WorkshopComposerDraft(input: WorkshopDraftInput(text: "", imageIds: []))
        precondition(!empty.hasUnsentInput)
        precondition(!WorkshopComposerDraft(input: WorkshopDraftInput(text: " \n", imageIds: [])).hasUnsentInput)
        precondition(WorkshopComposerDraft(input: WorkshopDraftInput(text: "", imageIds: ["photo"])).hasUnsentInput)
        try WorkshopDraftDisk.write(empty, to: first)
        try expect(nil, at: first, "Clearing the composer must not resurrect an older draft")
        try expect(editing, at: second)

        let blankEdit = WorkshopComposerDraft(input: empty.input, editingMessageID: "queued", originalInput: input)
        precondition(blankEdit.hasUnsentInput, "The original unsent input still needs its draft marker while editing a queued message")
        try WorkshopDraftDisk.write(blankEdit, to: second)
        try expect(blankEdit, at: second, "An empty edit must still retain the original input")

        let corrupt = directory.appendingPathComponent("corrupt.json")
        try Data("broken".utf8).write(to: corrupt)
        do {
            _ = try WorkshopDraftDisk.read(corrupt)
            preconditionFailure("A damaged draft must report an error instead of silently replacing it")
        } catch is DecodingError { }
        print("Workshop draft persistence tests passed")
    }
}
