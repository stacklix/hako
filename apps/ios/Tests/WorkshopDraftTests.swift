import Foundation

private final class DraftWrites: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [URL] = []
    private var failures = 0

    var count: Int { lock.lock(); defer { lock.unlock() }; return files.count }
    var failureCount: Int { lock.lock(); defer { lock.unlock() }; return failures }

    func write(_ draft: WorkshopComposerDraft, to file: URL) throws {
        lock.lock(); files.append(file); lock.unlock()
        try WorkshopDraftDisk.write(draft, to: file)
    }

    func receive(_ result: Result<Void, Error>) {
        if case .failure = result { lock.lock(); failures += 1; lock.unlock() }
    }
}

@main struct WorkshopDraftTests {
    static func expect(_ expected: WorkshopComposerDraft?, at file: URL, _ message: String = "Saved draft mismatch") throws {
        let actual = try WorkshopDraftDisk.read(file)
        precondition(actual == expected, message)
    }

    static func main() async throws {
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

        let writes = DraftWrites()
        let writer = WorkshopDraftWriter(delay: 60, writeFile: { try writes.write($0, to: $1) })
        for index in 1...100 {
            writer.write(WorkshopComposerDraft(input: WorkshopDraftInput(text: "输入 \(index)", imageIds: [])),
                to: first, completion: writes.receive)
        }
        await writer.flush()
        precondition(writes.count == 1, "Rapid edits must coalesce into one disk write")
        try expect(WorkshopComposerDraft(input: WorkshopDraftInput(text: "输入 100", imageIds: [])), at: first)

        let pendingFile = directory.appendingPathComponent("pending.json")
        let threadFile = directory.appendingPathComponent("thread.json")
        writer.write(draft, to: first, completion: writes.receive)
        writer.write(sending, to: pendingFile, removing: first, completion: writes.receive)
        writer.write(editing, to: threadFile, removing: pendingFile, completion: writes.receive)
        writer.write(blankEdit, to: threadFile, completion: writes.receive)
        await writer.flush()
        try expect(nil, at: first, "Coalesced session migration must remove all obsolete keys")
        try expect(nil, at: pendingFile)
        try expect(blankEdit, at: threadFile, "Migration must retain edits and the original composer")

        writer.write(draft, to: first, completion: writes.receive)
        writer.write(sending, to: threadFile, removing: first, completion: writes.receive)
        writer.write(editing, to: first, completion: writes.receive)
        await writer.flush()
        try expect(editing, at: first, "Migration cleanup must not delete newer input that reused an old key")
        try expect(sending, at: threadFile)

        writer.write(draft, to: first, completion: writes.receive)
        writer.write(empty, to: first, completion: writes.receive)
        writer.write(editing, to: second, completion: writes.receive)
        await writer.flush()
        await writer.flush()
        try expect(nil, at: first, "A cleared draft must not reappear after a later flush")
        try expect(editing, at: second, "Independent conversations must retain their own latest input")

        try WorkshopDraftDisk.write(draft, to: first)
        let impossible = corrupt.appendingPathComponent("cannot-write.json")
        writer.write(sending, to: impossible, removing: first, completion: writes.receive)
        await writer.flush()
        precondition(writes.failureCount == 1, "Asynchronous disk failures must be reported")
        try expect(draft, at: first, "Failed migration must preserve the recoverable original draft")
        try FileManager.default.removeItem(at: corrupt)
        await writer.flush()
        try expect(sending, at: impossible, "A later flush must retry a failed migration")
        try expect(nil, at: first, "Recovery must finish obsolete-key cleanup")

        let timedWriter = WorkshopDraftWriter(delay: 0.01)
        let completed: Bool = await withCheckedContinuation { continuation in
            timedWriter.write(draft, to: first) { result in
                if case .success = result { continuation.resume(returning: true) }
                else { continuation.resume(returning: false) }
            }
        }
        precondition(completed, "Input must persist automatically without waiting for the page to close")
        try expect(draft, at: first)
        print("Workshop draft persistence tests passed")
    }
}
