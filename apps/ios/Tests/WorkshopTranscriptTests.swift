import Foundation

@main struct WorkshopTranscriptTests {
    static func entry(_ id: String, _ text: String, kind: String = "item", role: String = "assistant", state: String = "") -> WorkshopEntry {
        WorkshopEntry(kind: kind, id: id, text: text, role: role, state: state, truncated: false)
    }

    static func main() throws {
        precondition(WorkshopWatchStep.next(operationId: "done", observedTerminal: "done", needsRecovery: true, busy: false) == .synchronize,
            "A connection failure after a completed turn must still reconnect")
        precondition(WorkshopWatchStep.next(operationId: "cached", observedTerminal: "cached", needsRecovery: true, busy: false) == .synchronize,
            "Unconfirmed cached operation state must be rechecked to unlock the composer")
        precondition(WorkshopWatchStep.next(operationId: nil, observedTerminal: nil, needsRecovery: true, busy: false) == .synchronize)
        precondition(WorkshopWatchStep.next(operationId: "live", observedTerminal: "previous", needsRecovery: false, busy: false) == .poll("live"))
        precondition(WorkshopWatchStep.next(operationId: "done", observedTerminal: "done", needsRecovery: false, busy: false) == .idle)
        precondition(WorkshopWatchStep.next(operationId: "live", observedTerminal: nil, needsRecovery: true, busy: true) == .idle)
        var scrolling = WorkshopScrollFollowing()
        scrolling.observe(nearBottom: false)
        precondition(scrolling.followsBottom, "A growing reply must not disable its own bottom anchor")
        scrolling.observe(nearBottom: true)
        scrolling.interacting(true); scrolling.interacting(false)
        precondition(scrolling.followsBottom, "Touching a list at the bottom must not permanently disable following")
        scrolling.interacting(true); scrolling.observe(nearBottom: false); scrolling.interacting(false)
        precondition(!scrolling.followsBottom, "Reading older messages must suspend following")
        scrolling.observe(nearBottom: false)
        precondition(!scrolling.followsBottom)
        scrolling.interacting(true); scrolling.observe(nearBottom: true); scrolling.interacting(false)
        precondition(scrolling.followsBottom, "Returning to the bottom must restore streaming response following")
        let queuedFirst = entry("queue-one", "Next request", kind: "followup", role: "user", state: "pending")
        let queuedSecond = entry("queue-two", "Another request", kind: "followup", role: "user", state: "queued")
        let beforeQueue = entry("before-queue", "Working")
        let laterRecord = entry("later-record", "Command", kind: "commandExecution", role: "")
        let laterReply = entry("later-reply", "Still working")
        let mixed = [beforeQueue, queuedFirst, laterRecord, queuedSecond, laterReply]
        let waiting = WorkshopTranscriptPresentation(entries: mixed, followups: [])
        precondition(waiting.history.map(\.id) == [beforeQueue.id, laterRecord.id, laterReply.id])
        precondition(waiting.queued.map(\.id) == [queuedFirst.id, queuedSecond.id],
            "Queued messages must remain below newer responses and tools in their original queue order")
        let growing = WorkshopTranscriptPresentation(entries: mixed + [entry("newest", "New response")], followups: [])
        precondition(growing.history.last?.id == "newest" && growing.queued == waiting.queued,
            "Additional streamed messages must not appear after waiting messages")
        precondition(mixed[1] == queuedFirst && mixed[3] == queuedSecond,
            "Presentation must not rewrite stored chronological history")
        for state in ["queued", "paused", "steering", "unknown"] {
            let presentation = WorkshopTranscriptPresentation(entries: mixed,
                followups: [WorkshopFollowupState(id: queuedFirst.id, state: state, revision: 1, imageIds: [])])
            precondition(presentation.queued == waiting.queued, "Unconsumed messages must stay at the bottom: " + state)
        }
        for state in ["starting", "running", "waiting", "finishing", "sent", "completed", "steered"] {
            let presentation = WorkshopTranscriptPresentation(entries: mixed,
                followups: [WorkshopFollowupState(id: queuedFirst.id, state: state, revision: 2, imageIds: [])])
            precondition(presentation.queued == [queuedSecond] && presentation.history.map(\.id) ==
                [beforeQueue.id, queuedFirst.id, laterRecord.id, laterReply.id],
                "Current operation state must release consumed messages from the queue even if cached entry state lags: " + state)
            precondition(presentation.history.count + presentation.queued.count == mixed.count,
                "State transitions must render every message exactly once")
        }
        let ordinaryUser = entry("ordinary-user", "Already sent", role: "user", state: "queued")
        precondition(WorkshopTranscriptPresentation(entries: [ordinaryUser], followups: []).queued.isEmpty,
            "An ordinary historical user message must not be mistaken for a pending follow-up")
        let prototype = WorkshopArtifact(id: "prototype", name: "demo", path: #"C:\Code\hako\docs\demo.html"#, threadId: "thread")
        let other = WorkshopArtifact(id: "other", name: "demo", path: #"C:\Code\hako\other\demo.html"#, threadId: "thread")
        let missing = WorkshopArtifact(id: "older", name: "older", path: #"C:\Code\hako\docs\older.html"#, threadId: "thread")
        let delivery = [
            entry("user", prototype.path, role: "user"),
            entry("change", prototype.path, kind: "fileChange", role: ""),
            entry("similar", "docs/demo.html.backup other/demo.html"),
            entry("reply", "[预览](/C:/Code/hako/docs/demo.html)"),
            entry("later", "继续修改"),
            entry("repeat", prototype.path)
        ]
        let placement = WorkshopArtifactPlacement.group([prototype, other, missing], entries: delivery, projectPath: #"C:\Code\hako"#)
        precondition(placement["reply"] == [prototype] && placement["similar"] == [other])
        precondition(placement.count == 2, "Cards belong to their delivered reply once, never to later messages or unrelated paths")
        let changedOnly = WorkshopArtifactPlacement.group([prototype], entries: [delivery[1]], projectPath: #"C:\Code\hako"#)
        precondition(changedOnly["change"] == [prototype])
        for reference in [#"{"path":"C:\\Code\\hako\\docs\\demo.html"}"#, "C%3A%5CCode%5Chako%5Cdocs%5Cdemo.html", "docs/demo.html", "C:/CODE/HAKO/docs/demo.html",
                          "\u{E200}visualize\u{E202}" + #"{"path":"C:/Code/hako/docs/demo.html"}"# + "\u{E201}"] {
            let grouped = WorkshopArtifactPlacement.group([prototype], entries: [entry("reply", reference)], projectPath: #"C:\Code\hako"#)
            precondition(grouped["reply"] == [prototype], "Windows, visualization JSON, encoded and relative references must match")
        }
        let noMatch = WorkshopArtifactPlacement.group([prototype], entries: [entry("wrong", "other/docs/demo.html docs/demo.html.backup")], projectPath: #"C:\Code\hako"#)
        precondition(noMatch.isEmpty, "A path fragment must not attach an unrelated prototype")

        let original = [entry("a", "Old"), entry("b", "Partial"), entry("c", "Recent")]
        var canonical = entry("request", "Same", role: "user")
        canonical.replacesId = "codex-item"
        let aliases = WorkshopTranscriptMerge.history([entry("request", "Same", role: "user"),
            entry("codex-item", "Same", role: "user"), entry("second-request", "Same", role: "user")], page: [canonical])
        precondition(aliases.map(\.id) == ["request", "second-request"], "Merge explicit aliases while preserving genuinely repeated messages")
        var liveAliases = [entry("codex-item", "Same", role: "user")]
        var aliasStream: [String: String] = [:]
        WorkshopTranscriptMerge.apply(canonical, entries: &liveAliases, streamText: &aliasStream)
        precondition(liveAliases.map(\.id) == ["request"])
        let merged = WorkshopTranscriptMerge.history(original, page: [entry("b", "Updated"), entry("c", "Recent"), entry("d", "New")])
        precondition(merged.map(\.id) == ["a", "b", "c", "d"])
        precondition(merged[1].text == "Updated", "A refresh must update existing content without dropping older pages")
        let older = WorkshopTranscriptMerge.history(merged, page: [entry("0", "Earlier"), entry("a", "Old")])
        precondition(older.map(\.id) == ["0", "a", "b", "c", "d"])
        precondition(WorkshopTranscriptMerge.history(older, page: older).count == older.count)

        var entries = [entry("answer", "Hello")]
        var stream: [String: String] = [:]
        WorkshopTranscriptMerge.apply(entry("answer", "He", kind: "delta"), entries: &entries, streamText: &stream)
        precondition(entries[0].text == "Hello", "Replaying a new operation must not shrink cached/canonical text")
        WorkshopTranscriptMerge.apply(entry("answer", "llo", kind: "delta"), entries: &entries, streamText: &stream)
        precondition(entries[0].text == "Hello", "History followed by operation replay must not double the reply")
        WorkshopTranscriptMerge.apply(entry("answer", "!", kind: "delta"), entries: &entries, streamText: &stream)
        precondition(entries[0].text == "Hello!")
        let key = WorkshopTranscriptKey(agentId: "computer", applicationId: "app", threadId: "thread")
        var snapshot = WorkshopTranscript(key: key, entries: entries, artifacts: [], followups: [], historyCursor: "24",
            operationId: "operation", eventCursor: 300, streamText: stream, savedAt: .now)
        let restored = try JSONDecoder().decode(WorkshopTranscript.self, from: JSONEncoder().encode(snapshot))
        var restoredEntries = restored.entries, restoredStream = restored.streamText
        WorkshopTranscriptMerge.apply(entry("answer", "?", kind: "delta"), entries: &restoredEntries, streamText: &restoredStream)
        precondition(restoredEntries[0].text == "Hello!?" && restored.eventCursor == 300)
        let lagging = WorkshopTranscriptMerge.history(restoredEntries, page: [entry("answer", "Hello")])
        precondition(lagging[0].text == "Hello!?", "An asynchronously refreshed history must not shorten a live reply")

        entries.append(entry("queued", "Pending", kind: "followup", role: "user", state: "queued"))
        WorkshopTranscriptMerge.apply(entry("queued", "", kind: "followup", role: "user", state: "cancelled"), entries: &entries, streamText: &stream)
        precondition(!entries.contains { $0.id == "queued" })
        precondition(WorkshopTranscriptPresentation(entries: entries, followups: []).queued.isEmpty,
            "Cancelled messages must disappear from the queue area as well as from history")
        snapshot.entries = older
        let bounded = try JSONDecoder().decode(WorkshopTranscript.self, from: snapshot.encodedForCache(maxEntries: 2)!)
        precondition(bounded.entries.map(\.id) == ["c", "d"] && bounded.historyCursor == nil)
        snapshot.streamText = ["large": String(repeating: "x", count: 8000)]
        let reset = try JSONDecoder().decode(WorkshopTranscript.self, from: snapshot.encodedForCache(maxBytes: 2000)!)
        precondition(reset.eventCursor == 0 && reset.streamText.isEmpty, "Dropping a replay accumulator must also reset its cursor")
        var differentDate = snapshot; differentDate.savedAt = .distantPast
        precondition(snapshot.hasSameContent(as: differentDate), "Unchanged polling should not rewrite cache files")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hako-transcript-" + UUID().uuidString, isDirectory: true)
        defer {
            if directory.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL,
               directory.lastPathComponent.hasPrefix("hako-transcript-") { try? FileManager.default.removeItem(at: directory) }
        }
        let url = directory.appendingPathComponent(String(repeating: "a", count: 64) + ".json")
        let disk = WorkshopTranscriptDisk()
        disk.write(snapshot, to: url)
        precondition(disk.read(url, key: key)?.key == key, "A subsequent read must see earlier queued writes")
        precondition(disk.read(url, key: WorkshopTranscriptKey(agentId: "other-computer", applicationId: "app", threadId: "thread")) == nil)
        precondition(disk.read(url, key: WorkshopTranscriptKey(agentId: "computer", applicationId: "other-app", threadId: "thread")) == nil)
        try Data("broken cache".utf8).write(to: url, options: .atomic)
        precondition(disk.read(url, key: key) == nil, "Invalid cache contents must not prevent online loading")
        var newest = url
        for index in 0..<55 {
            newest = directory.appendingPathComponent(String(format: "%064x", index) + ".json")
            disk.write(snapshot, to: newest)
        }
        precondition(disk.read(newest, key: key) != nil, "Eviction must retain the just-written conversation")
        let retained = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        precondition(retained.filter { $0.pathExtension == "json" }.count <= 50)
        print("PASS: queued messages at bottom, queue state transitions, transcript merge, resumed streams, atomic snapshots and cache isolation")
    }
}
