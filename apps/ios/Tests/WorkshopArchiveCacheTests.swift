import Foundation

private func digest(_ bytes: Data) -> String {
    let value = bytes.reduce(UInt64(1)) { ($0 &* 31) &+ UInt64($1) }
    return String(repeating: String(format: "%016llx", value), count: 4)
}

@main struct WorkshopArchiveCacheTests {
    static func snapshot(_ thread: String, _ text: String = "message", agent: String = "pc") -> WorkshopTranscript {
        WorkshopTranscript(key: WorkshopTranscriptKey(agentId: agent, applicationId: "app", threadId: thread),
            entries: [WorkshopEntry(kind: "item", id: "reply", text: text, role: "assistant", state: "completed", truncated: false)],
            artifacts: [], followups: [], eventCursor: 0, streamText: [:], savedAt: .now)
    }
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hako-archive-cache-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = snapshot("a"), b = snapshot("b"), otherAgent = snapshot("a", agent: "other-pc")
        let fileA = root.appendingPathComponent(String(repeating: "a", count: 64) + ".json")
        let fileB = root.appendingPathComponent(String(repeating: "b", count: 64) + ".json")
        let fileOther = root.appendingPathComponent(String(repeating: "c", count: 64) + ".json")
        let disk = WorkshopTranscriptDisk(delay: 60)
        disk.write(a, to: fileA); disk.write(b, to: fileB); disk.write(otherAgent, to: fileOther)
        await disk.flush()
        disk.write(snapshot("a", "pending snapshot"), to: fileA)
        let removed = try await disk.removeSession(agentID: "pc", threadID: "a", in: root)
        precondition(removed.removed.contains { $0.key == a.key } && removed.retained.contains { $0.key == b.key })
        precondition(!FileManager.default.fileExists(atPath: fileA.path) && FileManager.default.fileExists(atPath: fileB.path) &&
            FileManager.default.fileExists(atPath: fileOther.path), "Archive must affect only its computer and conversation")
        disk.write(a, to: fileA); await disk.flush()
        let archived = await disk.read(fileA, key: a.key)
        precondition(archived == nil && !FileManager.default.fileExists(atPath: fileA.path), "A late write recreated the archived transcript")
        let otherAccount = root.appendingPathComponent("other-account", isDirectory: true)
        try FileManager.default.createDirectory(at: otherAccount, withIntermediateDirectories: true)
        let otherAccountFile = otherAccount.appendingPathComponent(fileA.lastPathComponent)
        disk.write(a, to: otherAccountFile); await disk.flush()
        let otherAccountSnapshot = await disk.read(otherAccountFile, key: a.key)
        precondition(otherAccountSnapshot == a, "Archiving must not fence another account's copy of the same conversation")
        disk.allow(a.key, in: root); disk.write(a, to: fileA); await disk.flush()
        let restored = await disk.read(fileA, key: a.key)
        precondition(restored == a, "Unarchiving must permit newly loaded history to cache again")

        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let racing = WorkshopTranscriptDisk(delay: 60) { value, url in
            started.signal(); release.wait()
            try JSONEncoder().encode(value).write(to: url, options: .atomic)
        }
        racing.write(a, to: fileA)
        let flush = Task { await racing.flush() }
        let writing = await Task.detached { started.wait(timeout: .now() + 5) == .success }.value
        precondition(writing)
        let purge = Task { try await racing.removeSession(agentID: "pc", threadID: "a", in: root) }
        var fenced = false
        for _ in 0..<100 {
            if await racing.read(fileA, key: a.key) == nil { fenced = true; break }
            await Task.yield()
        }
        release.signal(); await flush.value; _ = try await purge.value
        precondition(fenced && !FileManager.default.fileExists(atPath: fileA.path), "An already running disk write must finish before deletion")

        let images = WorkshopProjectImageDisk(hash: { digest($0) })
        let ownerA = root.appendingPathComponent("images/a", isDirectory: true), ownerB = root.appendingPathComponent("images/b", isDirectory: true)
        let imageA = ownerA.appendingPathComponent("same.image"), imageB = ownerB.appendingPathComponent("same.image")
        let bytes = Data("cached image".utf8)
        try await images.write(bytes, revision: digest(bytes), to: imageA)
        try await images.write(bytes, revision: digest(bytes), to: imageB)
        try await images.removeSession(ownerA)
        try await images.write(bytes, revision: digest(bytes), to: imageA)
        let kept = await images.read(imageB)
        precondition(!FileManager.default.fileExists(atPath: ownerA.path) && kept?.0 == bytes,
            "Late image downloads must not recreate the archived directory or delete another conversation's copy")
        await images.allow(ownerA); try await images.write(bytes, revision: digest(bytes), to: imageA)
        precondition(FileManager.default.fileExists(atPath: imageA.path))

        let account = root.appendingPathComponent("account.json"), project = root.appendingPathComponent("project-images")
        let shared = "![shared](https://example.com/shared.png)"
        let oldA = WorkshopArchivedImageCleanup.previousFiles([snapshot("a", shared + "\n![unique](work/a.png)")],
            accountFile: account, projectDirectory: project, applications: ["app": "C:/Code/project"], hash: digest)
        let oldB = WorkshopArchivedImageCleanup.previousFiles([snapshot("b", shared)],
            accountFile: account, projectDirectory: project, applications: ["app": "C:/Code/project"], hash: digest)
        precondition(oldA.intersection(oldB).count == 1 && oldA.subtracting(oldB).count == 1,
            "Shared earlier image-cache entries must be retained for the other conversation")
        let upload = root.appendingPathComponent(UUID().uuidString + ".jpg")
        let orphan = root.appendingPathComponent(UUID().uuidString + ".jpg")
        try bytes.write(to: upload); try bytes.write(to: orphan)
        let draft = WorkshopComposerDraft(input: WorkshopDraftInput(text: "unsent", imageIds: [upload.deletingPathExtension().lastPathComponent]))
        try WorkshopDraftDisk.write(draft, to: root.appendingPathComponent("test.draft.json"))
        try WorkshopArchivedImageCleanup.remove(attachments: [], uploads: [upload, orphan], protecting: [], draftDirectory: root)
        precondition(FileManager.default.fileExists(atPath: upload.path) && !FileManager.default.fileExists(atPath: orphan.path),
            "An unsent draft's photo must survive sent-attachment cache cleanup")
        print("PASS: archive cache ownership, pending/running write fences, other conversation isolation, shared images, draft protection and unarchive")
    }
}
