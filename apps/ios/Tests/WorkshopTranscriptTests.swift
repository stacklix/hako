import Foundation

@main struct WorkshopTranscriptTests {
    static func entry(_ id: String, _ text: String, kind: String = "item", role: String = "assistant", state: String = "") -> WorkshopEntry {
        WorkshopEntry(kind: kind, id: id, text: text, role: role, state: state, truncated: false)
    }

    static func main() throws {
        let questionEntry = WorkshopEntry(kind: "item", id: "async-card", text: "请选择升级方式", role: "assistant", state: "", truncated: false,
            questions: [WorkshopAsyncQuestion(title: "如何升级？", options: ["同步升级"])])
        var questionEntries: [WorkshopEntry] = []
        var questionStream: [String: String] = [:]
        WorkshopTranscriptMerge.apply(questionEntry, entries: &questionEntries, streamText: &questionStream)
        precondition(questionEntries.first?.questions?.first?.options == ["同步升级"])
        let answerEntry = WorkshopEntry(kind: "followup", id: "answer-request", text: "同步升级", role: "user", state: "queued", truncated: false, questionId: "async-card")
        let answering = WorkshopTranscriptPresentation(entries: [questionEntry, answerEntry], followups: [WorkshopFollowupState(id: "answer-request", state: "steered", revision: 1, imageIds: [])])
        precondition(answering.history.last?.questionId == "async-card" && answering.history.last?.state == "steered")
        let questionCache = try! JSONEncoder().encode([questionEntry, answerEntry])
        let restoredQuestions = try! JSONDecoder().decode([WorkshopEntry].self, from: questionCache)
        precondition(restoredQuestions == [questionEntry, answerEntry])

        precondition(WorkshopWatchStep.next(operationId: "done", observedTerminal: "done", needsRecovery: true, busy: false) == .synchronize,
            "A connection failure after a completed turn must still reconnect")
        precondition(WorkshopWatchStep.next(operationId: "cached", observedTerminal: "cached", needsRecovery: true, busy: false) == .synchronize,
            "Unconfirmed cached operation state must be rechecked to unlock the composer")
        precondition(WorkshopWatchStep.next(operationId: nil, observedTerminal: nil, needsRecovery: true, busy: false) == .synchronize)
        precondition(WorkshopWatchStep.next(operationId: "live", observedTerminal: "previous", needsRecovery: false, busy: false) == .poll("live"))
        precondition(WorkshopWatchStep.next(operationId: "done", observedTerminal: "done", needsRecovery: false, busy: false) == .idle)
        precondition(WorkshopWatchStep.next(operationId: "live", observedTerminal: nil, needsRecovery: true, busy: true) == .idle)
        precondition(WorkshopWatchStep.delayMilliseconds(hasMoreEvents: true, failures: 0) == 30)
        precondition(WorkshopWatchStep.delayMilliseconds(hasMoreEvents: true, failures: 1) == 3000,
            "Buffered pages must not trigger a 30ms reconnect loop while disconnected")
        precondition(WorkshopWatchStep.delayMilliseconds(hasMoreEvents: false, failures: 1) == 3000)
        precondition(WorkshopWatchStep.delayMilliseconds(hasMoreEvents: true, failures: 20) == 15000)
        let staleNotice = WorkshopEntry(kind: "notice", id: "error-recovered", text: "Unknown old result", role: "", state: "", truncated: false)
        let otherNotice = WorkshopEntry(kind: "notice", id: "error-other", text: "Still unknown", role: "", state: "", truncated: false)
        for state in ["completed", "interrupted", "failed"] {
            precondition(WorkshopTranscriptMerge.withoutRecoveredNotices([staleNotice, otherNotice], operationId: "recovered", state: state, followups: []) == [otherNotice])
        }
        precondition(WorkshopTranscriptMerge.withoutRecoveredNotices([staleNotice], operationId: "recovered", state: "unknown", followups: []) == [staleNotice],
            "A history refresh alone cannot remove a genuinely unknown outcome")
        let generatedPicture = WorkshopEntry(kind: "imageGeneration", id: "image-output", text: "[图片 × 1]", role: "assistant", state: "completed", truncated: false)
        let imageHistory = WorkshopTranscriptMerge.history([], page: [generatedPicture])
        precondition(imageHistory == [generatedPicture], "Generated picture items must remain in canonical history")
        let restoredPicture = try! JSONDecoder().decode([WorkshopEntry].self, from: JSONEncoder().encode(imageHistory))
        precondition(restoredPicture.first?.kind == "imageGeneration" && restoredPicture.first?.id == "image-output")
        let resumeNow = Date(timeIntervalSince1970: 1000)
        precondition(WorkshopWatchStep.onEntry(lastVerifiedAt: resumeNow.addingTimeInterval(-59), now: resumeNow,
            operationId: "live", observedTerminal: nil, needsRecovery: false, busy: false) == .poll("live"),
            "Reopening a recently verified running conversation must resume incremental polling without full history synchronization")
        precondition(WorkshopWatchStep.onEntry(lastVerifiedAt: resumeNow, now: resumeNow,
            operationId: "done", observedTerminal: "done", needsRecovery: false, busy: false) == .idle,
            "An unchanged completed conversation must be immediately usable on a quick return")
        for verified in [Date?.none, resumeNow.addingTimeInterval(-60), resumeNow.addingTimeInterval(1)] {
            precondition(WorkshopWatchStep.onEntry(lastVerifiedAt: verified, now: resumeNow,
                operationId: "live", observedTerminal: nil, needsRecovery: false, busy: false) == .synchronize,
                "Cold, expired or clock-adjusted conversations must verify history before trusting cached operation state")
        }
        precondition(WorkshopWatchStep.onEntry(lastVerifiedAt: resumeNow, now: resumeNow,
            operationId: "live", observedTerminal: nil, needsRecovery: true, busy: false) == .synchronize,
            "A recent timestamp must not bypass connection recovery or an uncertain send result")
        precondition(WorkshopWatchStep.onEntry(lastVerifiedAt: nil, now: resumeNow,
            operationId: "live", observedTerminal: nil, needsRecovery: true, busy: true) == .idle,
            "Reentry must not start overlapping reads while a send or synchronization is already running")
        func session(_ time: Int64, state: String = "running", operation: String = "live", completion: String? = nil) -> WorkshopSession {
            WorkshopSession(id: "thread", title: "Session", applicationId: "app", cwd: "project", preview: "Reply",
                updatedAt: time, state: state, operationId: operation, completionId: completion)
        }
        let catalogBefore = session(1)
        precondition(!WorkshopWatchStep.catalogNeedsSynchronization(previous: catalogBefore, current: session(2),
            operationId: "live", operationActive: true, completionId: nil),
            "Updates from the same live worker can be read from the saved event cursor")
        precondition(WorkshopWatchStep.catalogNeedsSynchronization(previous: catalogBefore, current: session(2, operation: "other"),
            operationId: "live", operationActive: true, completionId: nil), "A different worker must force history reconciliation")
        let finishedCatalog = session(2, state: "completed", completion: "turn-two")
        precondition(!WorkshopWatchStep.catalogNeedsSynchronization(previous: catalogBefore, current: finishedCatalog,
            operationId: "live", operationActive: false, completionId: "turn-two"),
            "A completion already read inside the conversation must not cause another full sync on return")
        precondition(WorkshopWatchStep.catalogNeedsSynchronization(previous: catalogBefore, current: finishedCatalog,
            operationId: "live", operationActive: false, completionId: "turn-one"),
            "A completion received while away must be reconciled before reusing the conversation")
        precondition(WorkshopWatchStep.catalogNeedsSynchronization(previous: catalogBefore,
            current: session(2, state: "completed", operation: "new-worker", completion: "turn-two"),
            operationId: "live", operationActive: false, completionId: "turn-two"),
            "A changed worker cannot be ignored even when the last completion is unchanged")
        var scrolling = WorkshopScrollFollowing()
        precondition(scrolling.shouldFollowUpdates, "Opening a conversation must follow its first asynchronously laid-out messages")
        scrolling.observe(nearBottom: false)
        precondition(scrolling.followsBottom, "A growing reply must not disable its own bottom anchor")
        precondition(scrolling.shouldFollowUpdates, "Initial estimated geometry must not disable the persistent bottom target")
        scrolling.observe(nearBottom: true)
        scrolling.interacting(true)
        precondition(!scrolling.shouldFollowUpdates, "Streaming updates must not interrupt a user's scroll gesture")
        scrolling.interacting(false)
        precondition(scrolling.followsBottom, "Touching a list at the bottom must not permanently disable following")
        scrolling.interacting(true); scrolling.observe(nearBottom: false); scrolling.interacting(false)
        precondition(!scrolling.followsBottom, "Reading older messages must suspend following")
        precondition(!scrolling.shouldFollowUpdates)
        scrolling.observe(nearBottom: false)
        precondition(!scrolling.followsBottom)
        scrolling.interacting(true); scrolling.observe(nearBottom: true); scrolling.interacting(false)
        precondition(scrolling.followsBottom, "Returning to the bottom must restore streaming response following")
        precondition(scrolling.shouldFollowUpdates)
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
            precondition(presentation.queued.map(\.id) == waiting.queued.map(\.id), "Unconsumed messages must stay at the bottom: " + state)
            precondition(presentation.queued.first?.state == state && presentation.queued.last == queuedSecond,
                "Pending rows must receive their current state without changing the next queued message")
        }
        for state in ["starting", "running", "waiting", "finishing", "sent", "completed", "steered"] {
            let presentation = WorkshopTranscriptPresentation(entries: mixed,
                followups: [WorkshopFollowupState(id: queuedFirst.id, state: state, revision: 2, imageIds: [])])
            precondition(presentation.queued == [queuedSecond] && presentation.history.map(\.id) ==
                [beforeQueue.id, queuedFirst.id, laterRecord.id, laterReply.id],
                "Current operation state must release consumed messages from the queue even if cached entry state lags: " + state)
            precondition(presentation.history.count + presentation.queued.count == mixed.count,
                "State transitions must render every message exactly once")
            precondition(presentation.history.first(where: { $0.id == queuedFirst.id })?.state == state,
                "A consumed message must display its acknowledged state: " + state)
        }
        let ordinaryUser = entry("ordinary-user", "Already sent", role: "user", state: "queued")
        let steerAcknowledgement = WorkshopFollowupState(id: queuedFirst.id, state: "steered", revision: 1, imageIds: [])
        let staleQueueSnapshot = WorkshopFollowupState(id: queuedFirst.id, state: "queued", revision: 0, imageIds: [])
        let acknowledged = WorkshopFollowupState.merging([staleQueueSnapshot], into: [steerAcknowledgement])
        let afterSteer = WorkshopTranscriptPresentation(entries: mixed, followups: acknowledged)
        precondition(afterSteer.queued == [queuedSecond] && afterSteer.history.contains(where: { $0.id == queuedFirst.id }),
            "Late queued metadata must not send an acknowledged Steer message back to the pending queue")
        precondition(afterSteer.history.first(where: { $0.id == queuedFirst.id })?.state == "steered",
            "A Steer acknowledgement must change the row's displayed value immediately, even when its cached event still says queued")
        var linkedFollowup = queuedFirst
        linkedFollowup.questionId = "question"
        linkedFollowup.replacesId = "canonical-message"
        linkedFollowup.questions = [WorkshopAsyncQuestion(title: "Question", options: ["Yes"])]
        let resolved = WorkshopTranscriptPresentation(entries: [linkedFollowup], followups: [steerAcknowledgement]).history[0]
        precondition(resolved.state == "steered" && resolved.id == linkedFollowup.id && resolved.text == linkedFollowup.text &&
            resolved.questionId == linkedFollowup.questionId && resolved.replacesId == linkedFollowup.replacesId && resolved.questions == linkedFollowup.questions,
            "Resolving the visible state must preserve the message identity, content and question metadata")
        let cachedStatuses = try JSONDecoder().decode([WorkshopFollowupState].self, from: JSONEncoder().encode(acknowledged))
        precondition(WorkshopFollowupState.merging([staleQueueSnapshot], into: cachedStatuses) == [steerAcknowledgement],
            "Restoring a conversation must preserve acknowledgement against a stale snapshot")
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
        let steeredReceipt = entry("request", "Same", kind: "followup", role: "user", state: "steered")
        var duplicateSteer = WorkshopTranscriptMerge.history([steeredReceipt,
            entry("codex-item", "Same", role: "user"), entry("second-request", "Same", role: "user")], page: [canonical])
        precondition(duplicateSteer.map(\.id) == ["request", "second-request"] && duplicateSteer[0].kind == "item",
            "A Steer receipt and its canonical bubble must merge while a genuinely repeated request remains distinct")
        WorkshopTranscriptMerge.apply(entry("request", "Same", kind: "followup", role: "user", state: "queued"),
            entries: &duplicateSteer, streamText: &aliasStream)
        precondition(duplicateSteer.map(\.id) == ["request", "second-request"] && duplicateSteer[0].kind == "item",
            "Replaying a queued receipt after canonical history must not recreate the duplicate card")
        let merged = WorkshopTranscriptMerge.history(original, page: [entry("b", "Updated"), entry("c", "Recent"), entry("d", "New")])
        precondition(merged.map(\.id) == ["a", "b", "c", "d"])
        precondition(merged[1].text == "Updated", "A refresh must update existing content without dropping older pages")
        let older = WorkshopTranscriptMerge.history(merged, page: [entry("0", "Earlier"), entry("a", "Old")])
        precondition(older.map(\.id) == ["0", "a", "b", "c", "d"])
        precondition(WorkshopTranscriptMerge.history(older, page: older).count == older.count)

        let oldPrompt = entry("old-prompt", "First request", role: "user")
        let oldProgress = entry("old-progress", "Working on the first request")
        let oldTool = entry("old-tool", "Run command", kind: "commandExecution", role: "")
        let oldFinal = entry("old-final", "First request completed")
        let nextPrompt = entry("next-prompt", "Second request", kind: "followup", role: "user", state: "queued")
        let lastPrompt = entry("last-prompt", "Third request", kind: "followup", role: "user", state: "queued")
        var turns = [oldPrompt, oldProgress]
        var turnStream: [String: String] = [:]
        WorkshopTranscriptMerge.apply(nextPrompt, entries: &turns, streamText: &turnStream)
        WorkshopTranscriptMerge.apply(oldTool, entries: &turns, streamText: &turnStream)
        WorkshopTranscriptMerge.apply(lastPrompt, entries: &turns, streamText: &turnStream)
        WorkshopTranscriptMerge.apply(oldFinal, entries: &turns, streamText: &turnStream)
        precondition(turns.map(\.id) == [oldPrompt.id, oldProgress.id, oldTool.id, oldFinal.id, nextPrompt.id, lastPrompt.id],
            "Tools and the final reply of the current request must precede later queued requests")
        let startingPrompt = entry(nextPrompt.id, nextPrompt.text, kind: "followup", role: "user", state: "starting")
        WorkshopTranscriptMerge.apply(startingPrompt, entries: &turns, streamText: &turnStream)
        WorkshopTranscriptMerge.apply(entry("next-reply", "Second response", kind: "delta"), entries: &turns, streamText: &turnStream)
        precondition(turns.map(\.id) == [oldPrompt.id, oldProgress.id, oldTool.id, oldFinal.id, nextPrompt.id, "next-reply", lastPrompt.id],
            "Consuming a queued request must place it after the previous complete response and before its own response")
        let canonicalPrompt = entry(nextPrompt.id, nextPrompt.text, role: "user")
        let interleaved = [oldPrompt, oldProgress, nextPrompt, oldTool, oldFinal, entry("next-reply", "Second response, streamed further")]
        let reconciled = WorkshopTranscriptMerge.history(interleaved,
            page: [oldFinal, canonicalPrompt, entry("next-reply", "Second response")])
        precondition(reconciled.map(\.id) == [oldPrompt.id, oldProgress.id, oldTool.id, oldFinal.id, nextPrompt.id, "next-reply"],
            "Canonical turn order must move an optimistic request out of the middle of the preceding response")
        precondition(reconciled.last?.text == "Second response, streamed further", "Correcting turn order must not shorten a live response")
        precondition(WorkshopTranscriptMerge.history(reconciled,
            page: [oldFinal, canonicalPrompt, entry("next-reply", "Second response")]).map(\.id) == reconciled.map(\.id),
            "Repeated history refreshes must keep corrected turn order stable")
        var replayedTurns = reconciled
        WorkshopTranscriptMerge.apply(nextPrompt, entries: &replayedTurns, streamText: &turnStream)
        WorkshopTranscriptMerge.apply(startingPrompt, entries: &replayedTurns, streamText: &turnStream)
        precondition(replayedTurns == reconciled,
            "Replayed queue/start events must not move a canonical sent request behind its already-rendered reply")
        var startedTurns = [oldPrompt, oldFinal, startingPrompt, entry("next-reply", "Partial second response")]
        WorkshopTranscriptMerge.apply(nextPrompt, entries: &startedTurns, streamText: &turnStream)
        precondition(startedTurns[2] == startingPrompt && startedTurns[3].id == "next-reply",
            "An older queued receipt cannot downgrade a request that has already started")
        var consumedWithoutHistory = interleaved
        WorkshopTranscriptMerge.apply(canonicalPrompt, entries: &consumedWithoutHistory, streamText: &turnStream)
        precondition(consumedWithoutHistory.firstIndex { $0.id == nextPrompt.id }! > consumedWithoutHistory.firstIndex { $0.id == oldFinal.id }!,
            "A canonical user event must never restore the old optimistic insertion position")

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
        print("PASS: complete turn ordering, queued-request consumption, canonical/replay stability, warm resume and cache isolation")
    }
}
