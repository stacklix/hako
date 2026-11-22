import Foundation

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}

@main struct WorkshopPerformanceTests {
    static func entry(_ id: String, _ text: String, kind: String = "item", role: String = "assistant", state: String = "") -> WorkshopEntry {
        WorkshopEntry(kind: kind, id: id, text: text, role: role, state: state, truncated: false)
    }

    static func main() async throws {
        let question = WorkshopAsyncQuestion(title: "如何更新？", options: ["立即更新"])
        let questionEntry = WorkshopEntry(kind: "item", id: "question", text: "请选择", role: "assistant", state: "",
            truncated: false, questions: [question])
        let answerText = WorkshopAsyncQuestion.replyMessage([question], answers: [0: "立即更新\n保留我的设置"])!
        let answerEntry = WorkshopEntry(kind: "followup", id: "answer", text: answerText, role: "user", state: "queued",
            truncated: false, questionId: questionEntry.id)
        let questionRenderer = WorkshopTranscriptRenderer()
        let queuedReply = await questionRenderer.render(entries: [questionEntry, answerEntry], followups: [],
            artifacts: [], projectPath: "/project", revision: 1)
        let expectedReply = [WorkshopQuestionReply(question: question.title, answer: "立即更新\n保留我的设置")]
        precondition(queuedReply.questionReplies[answerEntry.id] == expectedReply && queuedReply.queued.count == 1)
        let acceptedReply = await questionRenderer.render(entries: [questionEntry, answerEntry],
            followups: [WorkshopFollowupState(id: answerEntry.id, state: "steered", revision: 1, imageIds: [])],
            artifacts: [], projectPath: "/project", revision: 2)
        precondition(acceptedReply.questionReplies[answerEntry.id] == expectedReply && acceptedReply.queued.isEmpty,
            "Question/answer sections must survive the queued-to-accepted transition")
        let unlinked = await questionRenderer.render(entries: [entry("ordinary", answerText, role: "user")],
            followups: [], artifacts: [], projectPath: "/project", revision: 3)
        precondition(unlinked.questionReplies.isEmpty, "Ordinary user text must not be reclassified as a linked answer")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hako-workshop-performance-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = WorkshopTranscriptKey(agentId: "agent", applicationId: "app", threadId: "thread")
        var snapshot = WorkshopTranscript(key: key, entries: [], artifacts: [], followups: [], eventCursor: 0, streamText: [:], savedAt: .now)
        let file = directory.appendingPathComponent("transcript.json")

        let writes = Counter()
        let disk = WorkshopTranscriptDisk(delay: 60) { value, url in
            writes.increment()
            try JSONEncoder().encode(value).write(to: url, options: .atomic)
        }
        for cursor in 1...100 {
            snapshot.eventCursor = Int64(cursor)
            snapshot.entries = [entry("reply", "Fragment \(cursor)")]
            snapshot.streamText = ["reply": "Fragment \(cursor)"]
            disk.write(snapshot, to: file)
        }
        let pending = await disk.read(file, key: key)
        precondition(pending?.eventCursor == 100 && pending?.streamText["reply"] == "Fragment 100")
        precondition(writes.value == 0, "Opening a pending transcript must not force synchronous persistence")
        await disk.flush()
        precondition(writes.value == 1, "100 streaming updates must coalesce into one snapshot write")
        let saved = await disk.read(file, key: key)
        precondition(saved == snapshot, "Cursor, accumulated text and entries must persist together")

        // Simulate a stalled filesystem: enqueue updates while an earlier write
        // is running, then verify opening the latest snapshot still completes.
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let blockedWrites = Counter(), reads = Counter()
        let blocked = WorkshopTranscriptDisk(delay: 60) { value, url in
            blockedWrites.increment()
            if blockedWrites.value == 1 { started.signal(); release.wait() }
            try JSONEncoder().encode(value).write(to: url, options: .atomic)
        }
        blocked.write(snapshot, to: file)
        let firstFlush = Task { await blocked.flush() }
        let didStart = await Task.detached { started.wait(timeout: .now() + 5) == .success }.value
        precondition(didStart)
        for cursor in 101...200 { snapshot.eventCursor = Int64(cursor); blocked.write(snapshot, to: file) }
        let read = Task {
            let value = await blocked.read(file, key: key)
            if value?.eventCursor == 200 { reads.increment() }
        }
        for _ in 0..<100 where reads.value == 0 { try await Task.sleep(for: .milliseconds(5)) }
        let completedBeforeDisk = reads.value == 1
        release.signal()
        await firstFlush.value; await read.value; await blocked.flush()
        precondition(completedBeforeDisk, "A slow write must not block opening the newest cached conversation")
        precondition(blockedWrites.value == 2, "Updates during a slow write must retain only the latest waiting snapshot")

        let state = WorkshopPersistence()
        let stateFile = directory.appendingPathComponent("state.json")
        state.schedule(["state": "pending"], to: stateFile) { _ in }
        try state.write(["state": "new durable send"], to: stateFile)
        await state.flush()
        let durable = try state.read([String: String].self, from: stateFile)
        precondition(durable["state"] == "new durable send",
            "An old background acknowledgement must not overwrite a new durable send")
        let failed = Counter()
        state.schedule(["state": "invalid"], to: stateFile.appendingPathComponent("child.json")) { result in
            if case .failure = result { failed.increment() }
        }
        await state.flush()
        precondition(failed.value == 1, "Background persistence failures must be reported")

        let stateWrites = Counter(), stateCompletions = Counter()
        let coalescing = WorkshopPersistence(delay: 60) { data, file in
            stateWrites.increment()
            try data.write(to: file, options: .atomic)
        }
        for revision in 1...100 {
            coalescing.schedule(["revision": revision], to: stateFile) { result in
                if case .success = result { stateCompletions.increment() }
            }
        }
        await coalescing.flush()
        let latestState = try await coalescing.readAsync([String: Int].self, from: stateFile)
        precondition(stateWrites.value == 1 && stateCompletions.value == 100 && latestState["revision"] == 100,
            "Rapid list refreshes must persist only the latest state and complete all waiting callbacks")
        coalescing.schedule(["revision": 101], to: stateFile) { _ in }
        try coalescing.write(["revision": 102], to: stateFile)
        await coalescing.flush()
        let afterDurableSend = try await coalescing.readAsync([String: Int].self, from: stateFile)
        let quotaFile = directory.appendingPathComponent("quota.json")
        coalescing.schedule(["quota": 42], to: quotaFile) { _ in }
        try await coalescing.remove(quotaFile)
        await coalescing.flush()
        precondition(!FileManager.default.fileExists(atPath: quotaFile.path),
            "Clearing quota must not be undone by a previously scheduled cache write")
        try await coalescing.remove(quotaFile)
        let preservedState = try await coalescing.readAsync([String: Int].self, from: stateFile)
        precondition(preservedState == afterDurableSend, "Clearing quota must preserve conversation state")
        precondition(afterDurableSend["revision"] == 102, "A delayed list save must never overwrite a later durable write")

        let parses = Counter()
        let renderer = WorkshopTranscriptRenderer { text in parses.increment(); return WorkshopMessage.parts(text) }
        var history = (0..<300).map { entry("message-\($0)", "Message \($0): **text** and `code`.") }
        let artifact = WorkshopArtifact(id: "prototype", name: "Preview", path: "C:/Code/app/docs/demo.html", threadId: "thread")
        history.append(entry("file", "C:/Code/app/docs/demo.html\n+contents", kind: "fileChange", role: ""))
        history.append(entry("live", "See docs/demo.html"))
        let first = await renderer.render(entries: history, followups: [], artifacts: [artifact], projectPath: "C:/Code/app", revision: 1)
        precondition(parses.value == 301 && first.artifactsByEntry["live"] == [artifact])
        history[history.count - 1].text += "\n\n```swift\nlet value = 1\n```"
        let updated = await renderer.render(entries: history, followups: [], artifacts: [artifact], projectPath: "C:/Code/app", revision: 2)
        precondition(parses.value == 302, "Streaming one reply must not reparse the 300 unchanged replies")
        precondition(updated.messageParts["live"]?.contains(.code("let value = 1", language: "swift")) == true)
        _ = await renderer.render(entries: history, followups: [], artifacts: [artifact], projectPath: "C:/Code/app", revision: 3)
        precondition(parses.value == 302, "Metadata updates must reuse parsed messages")
        history.removeLast()
        let removed = await renderer.render(entries: history, followups: [], artifacts: [artifact], projectPath: "C:/Code/app", revision: 4)
        precondition(removed.artifactsByEntry["file"] == [artifact] && removed.messageParts["live"] == nil,
            "Removing a reply must remove its parse cache and relocate its prototype")
        let renamed = WorkshopArtifact(id: artifact.id, name: artifact.name, path: "C:/Code/app/docs/new.html", threadId: artifact.threadId)
        let moved = await renderer.render(entries: history, followups: [], artifacts: [renamed], projectPath: "C:/Code/app", revision: 5)
        precondition(moved.artifactsByEntry.isEmpty, "A changed artifact path must invalidate old matches")

        var sequential = [entry("reply", "Hello"), entry("queued", "Next", kind: "followup", role: "user", state: "queued")]
        var batched = sequential
        var sequentialText: [String: String] = [:], batchedText: [String: String] = [:]
        let events = [entry("reply", "He", kind: "delta"), entry("reply", "llo", kind: "delta"),
            entry("reply", " 中文 👋", kind: "delta"), entry("reply", "Hello 中文 👋", state: "completed"),
            entry("tool", "run", kind: "commandExecution", role: ""), entry("next", "First", kind: "delta"),
            entry("next", " second", kind: "delta"), entry("queued", "Next", kind: "followup", role: "user", state: "running")]
        for event in events { WorkshopTranscriptMerge.apply(event, entries: &sequential, streamText: &sequentialText) }
        WorkshopTranscriptMerge.apply(events, entries: &batched, streamText: &batchedText)
        precondition(batched == sequential && batchedText == sequentialText,
            "Batching must preserve replay deduplication, Unicode, item boundaries and queue consumption")
        print("PASS: 100-to-1 snapshot coalescing, nonblocking reads during stalled writes, persistence ordering, 300 unchanged message parses reused, batched replay")
    }
}
