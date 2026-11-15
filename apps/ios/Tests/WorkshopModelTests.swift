import Foundation

@main struct WorkshopModelTests {
    static func main() throws {
        var visibility = WorkshopConversationVisibility()
        let pageA = UUID(), sheetB = UUID(), pageB = UUID(), conversationA = UUID(), conversationB = UUID()
        visibility.enter(pageA, conversation: conversationA, preview: false)
        visibility.enter(sheetB, conversation: conversationB, preview: true)
        precondition(visibility.foreground == [conversationB], "The preview, not the covered conversation, is being read")
        precondition(visibility.contains(conversationA), "A covered conversation must retain its messages and draft")
        visibility.leave(sheetB)
        precondition(visibility.foreground == [conversationA], "Closing a preview returns to the original conversation")
        visibility.enter(sheetB, conversation: conversationB, preview: true)
        visibility.enter(pageB, conversation: conversationB, preview: false)
        visibility.leave(sheetB); visibility.leave(pageA)
        precondition(visibility.foreground == [conversationB], "A sheet's disappearance cannot unregister the full page's owner")
        visibility.leave(pageB)
        precondition(visibility.foreground.isEmpty)
        precondition(WorkshopConnectionState.disconnected.beginningRequest == .connecting)
        precondition(WorkshopConnectionState.connected.beginningRequest == .connected,
            "Routine reads must not flash the project name on a healthy connection")
        for code in ["computer_offline", "workshop_disconnected", "workshop_timeout", "stream_overflow"] {
            precondition(WorkshopConnectionState.connected.afterFailure(WorkshopFailure(code: code, message: "Offline")) == .disconnected)
        }
        precondition(WorkshopConnectionState.connecting.afterFailure(URLError(.cannotConnectToHost)) == .disconnected)
        precondition(WorkshopConnectionState.connecting.afterFailure(CancellationError()) == .disconnected)
        precondition(WorkshopConnectionState.connected.afterFailure(CancellationError()) == .connected)
        precondition(WorkshopConnectionState.connecting.afterFailure(WorkshopFailure(code: "codex_busy", message: "Busy")) == .connected,
            "An application failure is still a reply from the Agent")
        precondition(WorkshopConnectionState.connected.accessibilityDescription == "电脑已连接",
            "Transport status must identify the computer connection, not imply Codex readiness")
        for state in ["failed", "unknown", "interrupted", "cancelled", "starting", "running", "waiting", "finishing", "completed"] {
            let operation = WorkshopOperation(id: "operation", applicationId: "app", threadId: "thread", turnId: nil,
                state: state, message: nil, startedAt: 1)
            precondition((operation.statusIcon == "checkmark.circle") == (state == "completed"),
                "Only a confirmed completed task may display a success icon: " + state)
        }
        precondition(WorkshopConnectionState.connecting.afterFailure(WorkshopFailure(code: "workshop_busy", message: "Server busy")) == .disconnected,
            "A broker response must not falsely verify an offline Agent")
        func timedOperation(_ state: String, start: Int64 = 1000, finish: Int64? = nil) -> WorkshopOperation {
            WorkshopOperation(id: "timed", applicationId: "app", threadId: "thread", turnId: "turn",
                state: state, message: nil, startedAt: start, finishedAt: finish)
        }
        for state in ["starting", "running", "waiting", "stopping", "finishing"] {
            let running = timedOperation(state)
            precondition(running.elapsedText(at: Date(timeIntervalSince1970: 1083.9)) == "1 分 23 秒")
            precondition(running.elapsedText(at: Date(timeIntervalSince1970: 1084)) == "1 分 24 秒",
                "Elapsed time must advance from the Agent's start, including when the view is reopened")
        }
        for state in ["completed", "failed", "interrupted"] {
            let ended = timedOperation(state, finish: 1083999)
            let reopened = try JSONDecoder().decode(WorkshopOperation.self, from: JSONEncoder().encode(ended))
            precondition(reopened.elapsedText(at: Date(timeIntervalSince1970: 5000)) == "1 分 23 秒",
                "Terminal durations must use the persisted millisecond timestamp, not when the phone reads them")
        }
        precondition(timedOperation("running").elapsedText(at: Date(timeIntervalSince1970: 1000)) == "0 秒")
        precondition(timedOperation("running").elapsedText(at: Date(timeIntervalSince1970: 1059)) == "59 秒")
        precondition(timedOperation("running").elapsedText(at: Date(timeIntervalSince1970: 1060)) == "1 分 0 秒")
        precondition(timedOperation("running").elapsedText(at: Date(timeIntervalSince1970: 4661)) == "1 小时 1 分 1 秒")
        precondition(timedOperation("running").elapsedText(at: Date(timeIntervalSince1970: 91061)) == "25 小时 1 分 1 秒")
        precondition(timedOperation("running").elapsedText(at: Date(timeIntervalSince1970: 999)) == "0 秒",
            "A clock difference must not display a negative duration")
        precondition(timedOperation("starting", start: 0).elapsedText(at: .now) == nil,
            "A queued task without a processing start must not count queue time")
        for state in ["completed", "unknown", "paused"] {
            precondition(timedOperation(state).elapsedText(at: .now) == nil, "Missing or uncertain end times must not be invented")
        }
        precondition(timedOperation("unknown", finish: 1083999).elapsedText(at: .now) == nil)
        precondition(WorkshopSystemPrompt.defaultText.contains("新的原型卡片") && WorkshopSystemPrompt.defaultText.contains("唯一") && WorkshopSystemPrompt.defaultText.contains("不得覆盖或复用"))
        precondition(WorkshopSystemPrompt.valid("") && !WorkshopSystemPrompt.valid(String(repeating: "a", count: 4001)) && !WorkshopSystemPrompt.valid("bad\0prompt"))
        precondition(!WorkshopSystemPrompt.valid(String(repeating: "😀", count: 2001)), "Prompt length must agree with the Agent's UTF-16 limit")
        var firstReceipt = WorkshopReceipt(id: "first", agentId: "pc", applicationId: "app", originalThreadId: nil,
            threadId: nil, title: "New", message: "Start", createdAt: .now, state: "pending", systemPrompt: "Initial instructions")
        precondition(firstReceipt.parameters["systemPrompt"] as? String == "Initial instructions")
        firstReceipt.threadId = "resolved-thread"
        let savedFirst = try JSONDecoder().decode(WorkshopReceipt.self, from: JSONEncoder().encode(firstReceipt))
        precondition(savedFirst.parameters["systemPrompt"] as? String == "Initial instructions", "Retrying the first request must retain its original prompt after thread resolution")
        let laterReceipt = WorkshopReceipt(id: "later", agentId: "pc", applicationId: "app", originalThreadId: "existing",
            threadId: "existing", title: "Existing", message: "Continue", createdAt: .now, state: "pending", systemPrompt: "Do not resend")
        precondition(laterReceipt.parameters["systemPrompt"] == nil, "Existing conversations never send the editable global prompt")
        let largeInitial = WorkshopReceipt(id: "large", agentId: "pc", applicationId: "app", originalThreadId: nil,
            threadId: nil, title: "New", message: String(repeating: "中", count: 4000), createdAt: .now, state: "pending", systemPrompt: String(repeating: "中", count: 4000))
        precondition(!largeInitial.fitsRequestBudget && firstReceipt.fitsRequestBudget,
            "Combined prompt/message size must be rejected locally before creating an uncertain send receipt")
        precondition(WorkshopQueuedSend(id: "queue", operationId: "first", message: "Follow-up", imageIds: []).parameters["systemPrompt"] == nil)
        let account = WorkshopCacheIdentity.account(serverURL: "https://hako.example", username: "alice")
        precondition(account == WorkshopCacheIdentity.account(serverURL: "https://hako.example", username: "alice"))
        precondition(account != WorkshopCacheIdentity.account(serverURL: "https://hako.example", username: "bob"))
        precondition(account != WorkshopCacheIdentity.account(serverURL: "https://other.example", username: "alice"))
        precondition(WorkshopCacheIdentity.account(serverURL: "a\nb", username: "c") !=
            WorkshopCacheIdentity.account(serverURL: "a", username: "b\nc"), "Account cache keys must not collide across field boundaries")
        let root = WorkshopApplication(id: "root", name: "Root", path: "C:\\Code\\")
        let project = WorkshopApplication(id: "project", name: "Project", path: "C:\\Code\\Hako\\")
        precondition(WorkshopApplication.containing("c:/code/hako", in: [root, project]) == project)
        precondition(WorkshopApplication.containing("C:\\CODE\\HAKO\\apps", in: [root, project]) == project,
            "Notification routing must choose the closest project, regardless of separator, case or trailing slash")
        precondition(WorkshopApplication.containing("C:/Code/Hako-other", in: [project]) == nil,
            "A project name prefix must not route a notification into a different project")
        precondition(WorkshopApplication.containing("/repo/app", in: [.init(id: "unix", name: "Unix", path: "/repo/")])?.id == "unix")
        let question = WorkshopAsyncQuestion(title: "如何升级？", options: ["同步升级", "保留兼容"])
        precondition(WorkshopAsyncQuestion.replyMessage([question], answers: [:]) == nil)
        precondition(WorkshopAsyncQuestion.replyMessage([question], answers: [0: " \n "]) == nil)
        precondition(WorkshopAsyncQuestion.replyMessage([question], answers: [0: "同步升级"]) == "针对提问的回答：\n如何升级？\n同步升级")
        precondition(WorkshopAsyncQuestion.replyMessage([question], answers: [0: String(repeating: "a", count: 4000)]) == nil)
        let answer = WorkshopQueuedSend(id: "reply", operationId: "op", message: "同步升级", imageIds: [], questionId: "async-question")
        precondition(answer.parameters["questionId"] as? String == "async-question" && answer.entry.questionId == "async-question")
        let restoredAnswer = try! JSONDecoder().decode(WorkshopQueuedSend.self, from: JSONEncoder().encode(answer))
        precondition(restoredAnswer.questionId == "async-question")

        let now = Date(timeIntervalSince1970: 1000)
        var completion = WorkshopSession(id: "thread", title: "Task", applicationId: "app", cwd: "project", preview: "Latest response", updatedAt: 1,
            state: "completed", operationId: nil, completionId: "turn-one")
        var reads = WorkshopReadState()
        precondition(reads.isUnread(completion, agentId: "computer-one", now: now))
        precondition(reads.markRead(threadId: completion.id, completionId: "turn-one", agentId: "computer-one"))
        precondition(!reads.markRead(threadId: completion.id, completionId: "turn-one", agentId: "computer-one"), "Repeated polling must not rewrite read receipts")
        let restoredReads = try JSONDecoder().decode(WorkshopReadState.self, from: JSONEncoder().encode(reads))
        precondition(!restoredReads.isUnread(completion, agentId: "computer-one", now: now), "Read state must survive reopening the app")
        precondition(restoredReads.isUnread(completion, agentId: "computer-two", now: now), "Read state must be scoped to the computer and conversation")
        completion.completionId = "turn-two"
        precondition(restoredReads.isUnread(completion, agentId: "computer-one", now: now), "A new completion with identical reply text must become unread")
        let renamed = WorkshopSession(id: "thread", title: "Renamed", applicationId: "app", cwd: "project", preview: "Latest response", updatedAt: 999,
            state: "completed", operationId: nil, completionId: "turn-one")
        precondition(!restoredReads.isUnread(renamed, agentId: "computer-one", now: now), "Renaming must not turn an already-read completion unread")
        let running = WorkshopSession(id: "thread", title: "Task", applicationId: "app", cwd: "project", preview: "New request", updatedAt: 999,
            state: "running", operationId: nil)
        precondition(running.inProgress && !restoredReads.isUnread(running, agentId: "computer-one", now: now))
        let deadline = Date(timeIntervalSince1970: Double(completion.updatedAt) + 12 * 60 * 60)
        precondition(restoredReads.isUnread(completion, agentId: "computer-one", now: deadline), "Exactly twelve hours remains unread")
        precondition(!restoredReads.isUnread(completion, agentId: "computer-one", now: deadline.addingTimeInterval(1)),
            "An unread completion must expire after twelve hours even without another server response")
        precondition(restoredReads.receipts["computer-one:thread"]?.completionId == "turn-one",
            "Expiring a badge must preserve the saved read receipt")
        let recentUnread = WorkshopSession(id: "recent", title: "Unread", applicationId: "app", cwd: "project", preview: "", updatedAt: 990,
            state: "completed", operationId: nil, completionId: "recent-turn")
        let ordinary = WorkshopSession(id: "ordinary", title: "Earlier read", applicationId: "app", cwd: "project", preview: "", updatedAt: 999,
            state: "idle", operationId: nil)
        let activityOrder = WorkshopCatalog.ordered([ordinary, completion, recentUnread])
        precondition(activityOrder.map(\.id) == [ordinary.id, recentUnread.id, completion.id],
            "Activity ordering must follow update times without granting unread conversations a separate priority")
        let equalTimeA = WorkshopSession(id: "a", title: "A", applicationId: "app", cwd: "project", preview: "", updatedAt: 999,
            state: "idle", operationId: nil)
        let equalTimeB = WorkshopSession(id: "b", title: "B", applicationId: "app", cwd: "project", preview: "", updatedAt: 999,
            state: "idle", operationId: nil)
        precondition(WorkshopCatalog.ordered([equalTimeB, equalTimeA]).map(\.id) == ["a", "b"],
            "Equal activity timestamps must have a stable order across refreshes")
        let older = WorkshopSession(id: "archived-elsewhere", title: "Earlier", applicationId: "app", cwd: "project", preview: "", updatedAt: 1, state: "idle", operationId: nil)
        let live = WorkshopSession(id: "live", title: "Live", applicationId: "app", cwd: "project", preview: "", updatedAt: 2, state: "idle", operationId: nil)
        let latest = WorkshopSession(id: "live", title: "Updated", applicationId: "app", cwd: "project", preview: "", updatedAt: 3, state: "idle", operationId: nil)
        precondition(WorkshopCatalog.merge([latest], existing: [older, live], more: false).map(\.id) == ["live"],
            "Refreshing must remove threads that were archived outside the phone")
        let more = WorkshopCatalog.merge([latest], existing: [older, live], more: true)
        precondition(more.map(\.id) == ["live", "archived-elsewhere"] && more[0].title == "Updated",
            "Pagination must retain earlier pages and reconcile duplicate thread IDs")
        let activated = WorkshopSession(id: older.id, title: older.title, applicationId: older.applicationId, cwd: older.cwd,
            preview: "New activity", updatedAt: 4, state: "running", operationId: "new-operation")
        let firstPage = WorkshopCatalog.merge([activated], existing: [latest, older], more: true)
        precondition(firstPage.map(\.id) == [older.id, latest.id] && firstPage[0].preview == "New activity",
            "Publishing the newest page must immediately move updated conversations forward while retaining older loaded pages")
        let caption = WorkshopImageCaption("附件说明\n\n[图片 × 2]")
        precondition(caption.text == "附件说明" && caption.count == 2)
        precondition(WorkshopImageCaption("\n[图片 × 1]").text.isEmpty)
        precondition(WorkshopImageCaption("这是正文 [图片 × 1]").count == 0)
        let original = WorkshopReceipt(id: UUID().uuidString, agentId: "Agent", applicationId: "app", originalThreadId: nil,
            threadId: nil, title: "New", message: "Hello", createdAt: .now, state: "pending")
        var resolved = original
        resolved.threadId = UUID().uuidString
        let application = WorkshopApplication(id: "app", name: "App", path: "project")
        var local = WorkshopLocalSessions()
        func listing(_ remote: [WorkshopSession] = [], agentId: String = "Agent", archived: Bool = false) -> [WorkshopSession] {
            local.merging(remote, agentId: agentId, applications: [application], archived: archived)
        }
        local.record(original, isNew: true)
        precondition(listing().first?.id == "pending-" + original.id,
            "A new send must appear immediately before any catalog response")
        precondition(listing(agentId: "other").isEmpty && listing(archived: true).isEmpty,
            "New conversations must stay scoped to their computer and active list")
        local.record(resolved, isNew: false)
        precondition(listing().count == 1 && listing()[0].id == resolved.threadId && listing()[0].inProgress,
            "Resolving the thread ID must replace the placeholder without waiting for the catalog")
        local.confirm([], agentId: "Agent")
        precondition(listing().first?.id == resolved.threadId,
            "An older in-flight catalog response must not hide a newly created thread")
        let remote = WorkshopSession(id: resolved.threadId!, title: "Remote title", applicationId: "app", cwd: "project",
            preview: "Remote response", updatedAt: Int64(original.createdAt.timeIntervalSince1970), state: "running", operationId: original.id)
        precondition(listing([remote]).count == 1 && listing([remote])[0].title == "Remote title",
            "The catalog must replace local data without a duplicate row")
        local.confirm([remote], agentId: "other")
        precondition(listing().count == 1, "Another computer cannot acknowledge this conversation")
        local.confirm([remote], agentId: "Agent")
        local.record(resolved, isNew: false)
        precondition(listing().isEmpty,
            "Later operation events must not resurrect an acknowledged thread after external archival")
        local.record(original, isNew: true)
        var rejected = original; rejected.state = "rejected"
        local.record(rejected, isNew: false)
        precondition(listing().isEmpty, "A rejected send must not leave a phantom conversation")
        local.record(resolved, isNew: true)
        local.remove(threadId: resolved.threadId!, agentId: "Agent")
        precondition(listing().isEmpty, "Archiving before catalog acknowledgement must remove the local row")
        let saved = try JSONDecoder().decode(WorkshopReceipt.self, from: JSONEncoder().encode(resolved))
        precondition(saved.threadId != nil)
        precondition(saved.parameters["threadId"] == nil, "A retry of a new thread must preserve the original request fingerprint")
        precondition(saved.parameters["requestId"] as? String == original.id)
        let previous = UUID().uuidString
        let continuing = WorkshopReceipt(id: UUID().uuidString, agentId: "Agent", applicationId: "app", originalThreadId: previous,
            threadId: previous, title: "Existing", message: "Continue", createdAt: .now, state: "pending")
        precondition(continuing.parameters["threadId"] as? String == previous)
        var activeList = WorkshopLocalSessions()
        let old = WorkshopSession(id: previous, title: "Existing", applicationId: "app", cwd: "project",
            preview: "Old reply", updatedAt: 100, state: "completed", operationId: "older-request")
        let recent = WorkshopSession(id: "other", title: "Other", applicationId: "app", cwd: "project",
            preview: "Other reply", updatedAt: 200, state: "completed", operationId: "other-request")
        func activeListing(_ remote: [WorkshopSession]) -> [WorkshopSession] {
            activeList.merging(remote, agentId: "Agent", applications: [application], archived: false)
        }
        activeList.record(continuing, isNew: true)
        let immediate = activeListing([recent, old])
        precondition(immediate.count == 2 && immediate[0].id == previous && immediate[0].inProgress,
            "Sending to an existing conversation must immediately move it to the top and mark it active")
        precondition(immediate[0].preview == continuing.message)
        activeList.confirm([old], agentId: "Agent")
        precondition(activeListing([recent, old])[0].inProgress,
            "An older catalog response for the same thread must not undo a new send")
        let staleTime = WorkshopSession(id: previous, title: "Existing", applicationId: "app", cwd: "project",
            preview: "Old reply", updatedAt: 100, state: "running", operationId: continuing.id)
        activeList.confirm([staleTime], agentId: "Agent")
        precondition(activeListing([recent, staleTime])[0].updatedAt == Int64(continuing.createdAt.timeIntervalSince1970),
            "Acknowledging the operation before the catalog timestamp updates must preserve the new activity time")
        var finished = continuing; finished.state = "completed"
        activeList.record(finished, isNew: false)
        precondition(!activeListing([staleTime])[0].inProgress, "A stale running catalog must not undo confirmed completion")
        var denied = continuing; denied.state = "rejected"
        activeList.record(denied, isNew: false)
        precondition(activeListing([recent, old]) == [recent, old], "Rejecting a send must restore the catalog's state and order")
        activeList.record(continuing, isNew: true)
        let acceptedSession = WorkshopSession(id: previous, title: "Existing", applicationId: "app", cwd: "project",
            preview: "Current", updatedAt: Int64(continuing.createdAt.timeIntervalSince1970), state: "running", operationId: continuing.id)
        activeList.confirm([acceptedSession], agentId: "Agent")
        activeList.record(continuing, isNew: false)
        precondition(activeListing([]).isEmpty, "After catalog acknowledgement, polling must not resurrect an archived thread")
        var updates = WorkshopSessionUpdates()
        let inFlight = updates.revision
        let verifiedDone = WorkshopSession(id: acceptedSession.id, title: acceptedSession.title, applicationId: "app", cwd: "project",
            preview: "Final reply", updatedAt: acceptedSession.updatedAt, state: "completed", operationId: continuing.id, completionId: "verified-turn")
        updates.record(verifiedDone, agentId: "Agent")
        let reconciled = updates.merging([acceptedSession], agentId: "Agent", since: inFlight)[0]
        precondition(!reconciled.inProgress && reconciled.completionId == "verified-turn",
            "A running catalog requested before detail confirmed completion must not restore a green icon")
        precondition(updates.merging([], agentId: "Agent", since: inFlight).isEmpty,
            "Verified state must not resurrect a session missing from a fresh catalog")
        precondition(updates.merging([acceptedSession], agentId: "other", since: inFlight)[0].inProgress)
        for _ in 0..<3 {
            let repeated = updates.merging([acceptedSession], agentId: "Agent", since: updates.revision)[0]
            precondition(!repeated.inProgress && repeated.completionId == "verified-turn",
                "Returning to the list and polling again must not undo verified completion without new activity")
        }
        let newTurn = WorkshopSession(id: previous, title: "Existing", applicationId: "app", cwd: "project",
            preview: "New task", updatedAt: verifiedDone.updatedAt + 1, state: "running", operationId: continuing.id)
        precondition(updates.merging([newTurn], agentId: "Agent", since: inFlight)[0].inProgress,
            "New activity in the same queue group must not be hidden by a previous completion")
        let newOperation = WorkshopSession(id: previous, title: "Existing", applicationId: "app", cwd: "project",
            preview: "New task", updatedAt: verifiedDone.updatedAt, state: "running", operationId: "different-operation")
        precondition(updates.merging([newOperation], agentId: "Agent", since: inFlight)[0].inProgress)
        let newCompletion = WorkshopSession(id: previous, title: "Existing", applicationId: "app", cwd: "project",
            preview: "Another completed turn", updatedAt: verifiedDone.updatedAt, state: "completed",
            operationId: continuing.id, completionId: "new-completion")
        precondition(updates.merging([newCompletion], agentId: "Agent", since: inFlight)[0].completionId == "new-completion",
            "A newly completed turn in the same timestamp bucket must retain its unread identity")
        for state in ["failed", "interrupted", "cancelled", "unknown", "paused"] {
            var terminalUpdates = WorkshopSessionUpdates()
            terminalUpdates.record(WorkshopSession(id: previous, title: "Existing", applicationId: "app", cwd: "project",
                preview: "Terminal", updatedAt: acceptedSession.updatedAt, state: state, operationId: continuing.id), agentId: "Agent")
            let result = terminalUpdates.merging([acceptedSession], agentId: "Agent", since: terminalUpdates.revision)[0]
            precondition(result.inProgress == ["unknown", "paused"].contains(state),
                "Verified terminal states must survive stale polls, while uncertain or paused operations can recover")
        }
        updates.remove(threadId: previous, agentId: "other")
        precondition(!updates.merging([acceptedSession], agentId: "Agent", since: updates.revision)[0].inProgress)
        updates.remove(threadId: previous, agentId: "Agent")
        precondition(updates.merging([acceptedSession], agentId: "Agent", since: updates.revision)[0].inProgress,
            "An explicit new send must allow resumed activity even in the same timestamp bucket")
        var settledActivity = WorkshopLocalSessions()
        let skewedDone = WorkshopSession(id: verifiedDone.id, title: verifiedDone.title, applicationId: "app", cwd: "project",
            preview: verifiedDone.preview, updatedAt: 100, state: "completed", operationId: continuing.id, completionId: "verified-turn")
        settledActivity.record(continuing, isNew: true)
        settledActivity.settle(threadId: previous, operationId: "unrelated", agentId: "Agent")
        precondition(!settledActivity.merging([skewedDone], agentId: "Agent", applications: [application], archived: false)[0].inProgress,
            "Completion of the exact operation must override a pending send even when the computer clock is behind")
        settledActivity.confirm([skewedDone], agentId: "Agent")
        precondition(settledActivity.merging([], agentId: "Agent", applications: [application], archived: false).isEmpty,
            "Catalog completion must remove the pending overlay without opening conversation details")
        settledActivity.settle(threadId: previous, operationId: continuing.id, agentId: "Agent")
        let settled = settledActivity.merging([skewedDone], agentId: "Agent", applications: [application], archived: false)[0]
        precondition(!settled.inProgress && settled.completionId == "verified-turn",
            "Verified completion must remove a pending-send overlay and retain unread/read identity")
        let queuedActivity = WorkshopReceipt(id: continuing.id, agentId: "Agent", applicationId: "app", originalThreadId: previous,
            threadId: previous, title: "Existing", message: "Queued follow-up", createdAt: continuing.createdAt.addingTimeInterval(2), state: "pending")
        activeList.record(queuedActivity, isNew: true, queued: true)
        activeList.record(continuing, isNew: false)
        activeList.confirm([acceptedSession], agentId: "Agent")
        let queuedListing = activeListing([acceptedSession, recent])
        precondition(queuedListing[0].preview == queuedActivity.message && queuedListing[0].updatedAt == Int64(queuedActivity.createdAt.timeIntervalSince1970),
            "Polling the parent operation must not replace a queued message's newer preview and activity time")
        activeList.confirm([verifiedDone], agentId: "Agent")
        precondition(activeListing([verifiedDone])[0].inProgress,
            "Completion of the parent must not clear a newer queued follow-up sharing its operation ID")
        activeList.reject(operationId: continuing.id, agentId: "Agent")
        precondition(activeListing([]).isEmpty, "Rejected queue activity must not leave a phantom running row")
        var verifiedActivity = WorkshopLocalSessions()
        verifiedActivity.record(continuing, isNew: true)
        let newerCatalog = WorkshopSession(id: previous, title: "Existing", applicationId: "app", cwd: "project",
            preview: "Latest reply", updatedAt: 300, state: "completed", operationId: "newer-operation", completionId: "newer-turn")
        precondition(verifiedActivity.merging([newerCatalog], agentId: "Agent", applications: [application], archived: false)[0].inProgress,
            "An unrelated catalog completion alone cannot discard an unconfirmed send")
        let verification = verifiedActivity.verifications(for: [newerCatalog], agentId: "Agent")[0]
        let oldCompleted = WorkshopOperation(id: continuing.id, applicationId: "app", threadId: previous,
            turnId: "older-turn", state: "completed", message: nil, startedAt: 1)
        let stillRunning = WorkshopOperation(id: continuing.id, applicationId: "app", threadId: previous,
            turnId: "older-turn", state: "running", message: nil, startedAt: 1)
        precondition(!verifiedActivity.verify(verification, operation: stillRunning, followups: []))
        let wrongThread = WorkshopOperation(id: continuing.id, applicationId: "app", threadId: "other-thread",
            turnId: "older-turn", state: "completed", message: nil, startedAt: 1)
        precondition(!verifiedActivity.verify(verification, operation: wrongThread, followups: []))
        precondition(verifiedActivity.verify(verification, operation: oldCompleted, followups: []))
        let verifiedListing = verifiedActivity.merging([newerCatalog], agentId: "Agent", applications: [application], archived: false)[0]
        precondition(!verifiedListing.inProgress && verifiedListing.operationId == "newer-operation" &&
            verifiedListing.completionId == "newer-turn" && verifiedListing.preview == "Latest reply",
            "Verifying an old request must remove its stale overlay without replacing newer catalog activity")
        verifiedActivity.record(continuing, isNew: true)
        let beforeQueue = verifiedActivity.verifications(for: [newerCatalog], agentId: "Agent")[0]
        verifiedActivity.record(queuedActivity, isNew: true, queued: true, queuedMessageId: "follow-up")
        precondition(!verifiedActivity.verify(beforeQueue, operation: oldCompleted, followups: []),
            "A delayed verification must not discard a newer queued message")
        let queueCheck = verifiedActivity.verifications(for: [newerCatalog], agentId: "Agent")[0]
        precondition(!verifiedActivity.verify(queueCheck, operation: oldCompleted, followups: []),
            "A parent result cannot confirm a follow-up the computer has not accepted")
        precondition(!verifiedActivity.verify(queueCheck, operation: oldCompleted,
            followups: [WorkshopFollowupState(id: "follow-up", state: "queued", revision: 0, imageIds: [])]))
        precondition(verifiedActivity.verify(queueCheck, operation: oldCompleted,
            followups: [WorkshopFollowupState(id: "follow-up", state: "completed", revision: 0, imageIds: [])]),
            "An identified completed follow-up must settle independently of phone/computer clock skew")
        verifiedActivity.record(continuing, isNew: true)
        let unconfirmed = verifiedActivity.verifications(for: [newerCatalog], agentId: "Agent")[0]
        precondition(!verifiedActivity.verify(unconfirmed, operation: oldCompleted, followups: [], pendingMessages: ["unconfirmed-message"]),
            "Persisted unconfirmed queued sends must survive a completed parent result")
        let sameSecond = WorkshopReceipt(id: "same-second", agentId: "Agent", applicationId: "app", originalThreadId: "z",
            threadId: "z", title: "Same second", message: "Latest", createdAt: Date(timeIntervalSince1970: 200.75), state: "pending")
        activeList.record(sameSecond, isNew: true)
        precondition(activeListing([recent])[0].id == "z", "Subsecond local sends must win timestamp ties without depending on the session ID")
        let operation = try JSONDecoder().decode(WorkshopOperation.self, from: Data("""
            {"id":"request","applicationId":"app","threadId":null,"turnId":null,"state":"finishing","message":null,"startedAt":1}
            """.utf8))
        precondition(operation.active, "A finishing worker must keep the composer disabled until the writer has exited")
        precondition(WorkshopChoice().permission == .auto, "New conversations must default to automatic review")
        var withImages = original
        withImages.model = "fixture-vision"
        withImages.permission = WorkshopPermission.auto.rawValue
        withImages.imageIds = [UUID().uuidString]
        withImages.serviceTier = "priority"
        withImages.reasoningEffort = "high"
        let roundTrip = try JSONDecoder().decode(WorkshopReceipt.self, from: JSONEncoder().encode(withImages))
        precondition(roundTrip.parameters["model"] as? String == "fixture-vision")
        precondition(roundTrip.parameters["permission"] as? String == "auto")
        precondition(roundTrip.parameters["imageIds"] as? [String] == withImages.imageIds)
        precondition(roundTrip.parameters["serviceTier"] as? String == "priority", "Retries must preserve the submitted speed")
        precondition(roundTrip.parameters["reasoningEffort"] as? String == "high", "A retry must use its originally submitted Intelligence")
        let reasoningModel = try JSONDecoder().decode(WorkshopModel.self, from: Data(#"{"id":"model","name":"Model","description":"Test","isDefault":true,"supportsImages":true,"serviceTiers":[],"defaultReasoningEffort":"low","reasoningEfforts":[{"id":"high","description":"Deep"},{"id":"low","description":"Quick"},{"id":"future-effort","description":"Future"}]}"#.utf8))
        precondition(reasoningModel.reasoningEfforts.map(\.id) == ["high", "low", "future-effort"])
        precondition(reasoningModel.reasoningEfforts.last?.title == "future-effort" && reasoningModel.defaultReasoningEffort == "low")
        precondition(reasoningModel.reasoningEfforts.first?.title == "高")
        precondition(reasoningModel.reasoningEfforts.first?.detail == "投入更多推理，适合复杂任务。")
        precondition(reasoningModel.reasoningEfforts.last?.detail == "Future")
        var reasoningChoice = WorkshopChoice(); reasoningChoice.reasoningEffort = "high"
        let restoredReasoningChoice = try JSONDecoder().decode(WorkshopChoice.self, from: JSONEncoder().encode(reasoningChoice))
        precondition(restoredReasoningChoice == reasoningChoice)
        precondition(WorkshopSpeed.standard.id == "default", "Standard must clear a previous priority override")
        let followup = try JSONDecoder().decode(WorkshopFollowupReply.self, from: Data("""
            {"id":"queued-message","message":"Focus on iOS","imageIds":[],"state":"queued","revision":2,"detail":null}
            """.utf8))
        precondition(followup.status.editable && followup.status.revision == 2)
        precondition(followup.entry.id == followup.id && followup.entry.kind == "followup" && followup.entry.state == "queued")
        let steered = WorkshopFollowupState(id: followup.id, state: "steered", revision: 3, imageIds: [])
        precondition(!steered.editable, "Accepted steering must not offer edit or cancel")
        var statuses = WorkshopFollowupState.merging([steered], into: [followup.status])
        precondition(statuses == [steered])
        statuses = WorkshopFollowupState.merging([followup.status], into: statuses)
        precondition(statuses == [steered], "A late queued snapshot or queue RPC reply must not undo accepted steering")
        for state in ["queued", "paused", "steering", "unknown"] {
            let stale = WorkshopFollowupState(id: steered.id, state: state, revision: steered.revision, imageIds: ["stale-image"])
            precondition(WorkshopFollowupState.merging([stale], into: statuses) == [steered],
                "A same-revision pre-acknowledgement state cannot overwrite steered: " + state)
        }
        precondition(WorkshopFollowupState.merging([], into: statuses) == [steered],
            "An older snapshot must not erase a request acknowledgement")
        let paused = WorkshopFollowupState(id: steered.id, state: "paused", revision: 4, imageIds: [])
        precondition(WorkshopFollowupState.merging([paused], into: statuses) == [paused], "Newer revisions remain authoritative")
        let steering = WorkshopFollowupState(id: paused.id, state: "steering", revision: 4, imageIds: [])
        precondition(WorkshopFollowupState.merging([paused], into: [steering]) == [paused],
            "A rejected steer must still be allowed to return to paused within its revision")
        let another = WorkshopFollowupState(id: "another-message", state: "queued", revision: 0, imageIds: [])
        precondition(WorkshopFollowupState.merging([another, followup.status], into: statuses) == [steered, another])
        let queued = WorkshopQueuedSend(id: "stable-message", operationId: "original-operation", message: "Hello", imageIds: ["image"], reasoningEffort: "high")
        let queuedRetry = try JSONDecoder().decode(WorkshopQueuedSend.self, from: JSONEncoder().encode(queued))
        precondition(queuedRetry.parameters["requestId"] as? String == "stable-message")
        precondition(queuedRetry.parameters["operationId"] as? String == "original-operation")
        precondition(queuedRetry.parameters["reasoningEffort"] as? String == "high")
        precondition(queuedRetry.entry.role == "user" && queuedRetry.entry.state == "pending")
        print("PASS: immediate new-session listing, catalog reconciliation, activity ordering, unread expiry and stable request identity")
    }
}
