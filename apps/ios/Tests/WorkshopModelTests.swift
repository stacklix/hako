import Foundation

@main struct WorkshopModelTests {
    static func main() throws {
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
        let queuedActivity = WorkshopReceipt(id: continuing.id, agentId: "Agent", applicationId: "app", originalThreadId: previous,
            threadId: previous, title: "Existing", message: "Queued follow-up", createdAt: continuing.createdAt.addingTimeInterval(2), state: "pending")
        activeList.record(queuedActivity, isNew: true)
        activeList.record(continuing, isNew: false)
        activeList.confirm([acceptedSession], agentId: "Agent")
        let queuedListing = activeListing([acceptedSession, recent])
        precondition(queuedListing[0].preview == queuedActivity.message && queuedListing[0].updatedAt == Int64(queuedActivity.createdAt.timeIntervalSince1970),
            "Polling the parent operation must not replace a queued message's newer preview and activity time")
        activeList.reject(operationId: continuing.id, agentId: "Agent")
        precondition(activeListing([]).isEmpty, "Rejected queue activity must not leave a phantom running row")
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
        let roundTrip = try JSONDecoder().decode(WorkshopReceipt.self, from: JSONEncoder().encode(withImages))
        precondition(roundTrip.parameters["model"] as? String == "fixture-vision")
        precondition(roundTrip.parameters["permission"] as? String == "auto")
        precondition(roundTrip.parameters["imageIds"] as? [String] == withImages.imageIds)
        precondition(roundTrip.parameters["serviceTier"] as? String == "priority", "Retries must preserve the submitted speed")
        precondition(WorkshopSpeed.standard.id == "default", "Standard must clear a previous priority override")
        let followup = try JSONDecoder().decode(WorkshopFollowupReply.self, from: Data("""
            {"id":"queued-message","message":"Focus on iOS","imageIds":[],"state":"queued","revision":2,"detail":null}
            """.utf8))
        precondition(followup.status.editable && followup.status.revision == 2)
        precondition(followup.entry.id == followup.id && followup.entry.kind == "followup" && followup.entry.state == "queued")
        let steered = WorkshopFollowupState(id: followup.id, state: "steered", revision: 3, imageIds: [])
        precondition(!steered.editable, "Accepted steering must not offer edit or cancel")
        let queued = WorkshopQueuedSend(id: "stable-message", operationId: "original-operation", message: "Hello", imageIds: ["image"])
        let queuedRetry = try JSONDecoder().decode(WorkshopQueuedSend.self, from: JSONEncoder().encode(queued))
        precondition(queuedRetry.parameters["requestId"] as? String == "stable-message")
        precondition(queuedRetry.parameters["operationId"] as? String == "original-operation")
        precondition(queuedRetry.entry.role == "user" && queuedRetry.entry.state == "pending")
        print("PASS: immediate new-session listing, catalog reconciliation, activity ordering, unread expiry and stable request identity")
    }
}
