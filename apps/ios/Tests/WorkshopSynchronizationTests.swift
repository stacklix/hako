import Foundation

@MainActor private final class Poller {
    var starts = 0
    var active = 0
    var maxActive = 0
    var ticks = 0

    func run() async {
        starts += 1; active += 1; maxActive = max(maxActive, active)
        defer { active -= 1 }
        while !Task.isCancelled {
            ticks += 1
            do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
        }
    }
}

@main struct WorkshopSynchronizationTests {
    @MainActor static func until(_ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !condition() {
            precondition(clock.now < deadline, "Synchronization lifecycle did not reach its expected state")
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @MainActor static func main() async throws {
        let sync = WorkshopSynchronization(grace: .milliseconds(200))
        let catalog = Poller(), conversation = Poller()
        let catalogID = UUID(), conversationID = UUID(), listOwner = UUID(), detailOwner = UUID()
        sync.register(catalogID, kind: .catalog) { await catalog.run() }
        sync.register(conversationID, kind: .conversation) { await conversation.run() }
        try await Task.sleep(for: .milliseconds(20))
        precondition(catalog.starts == 0 && conversation.starts == 0, "Registration must not start traffic before the sub-app is opened")
        sync.enter(listOwner, conversation: false)
        try await until { catalog.active == 1 && conversation.active == 1 }

        sync.leave(listOwner)
        sync.enter(detailOwner, conversation: true)
        try await until { catalog.active == 0 }
        precondition(conversation.starts == 1 && conversation.active == 1, "Entering a conversation must not restart its existing read loop")
        sync.enter(listOwner, conversation: false)
        sync.leave(detailOwner)
        try await until { catalog.active == 1 }
        precondition(conversation.starts == 1, "Returning to the list must keep the conversation continuously synchronized")

        let ticksBeforeExit = conversation.ticks
        sync.leave(listOwner)
        try await Task.sleep(for: .milliseconds(40))
        precondition(conversation.ticks > ticksBeforeExit && catalog.active == 1,
            "Both the catalog and conversation must keep syncing during the exit grace period")
        sync.enter(listOwner, conversation: false)
        try await Task.sleep(for: .milliseconds(220))
        precondition(conversation.starts == 1 && conversation.active == 1, "Reentry must cancel the previous expiration without restarting synchronization")

        sync.leave(listOwner)
        try await until { conversation.active == 0 && catalog.active == 0 }
        let stoppedTicks = conversation.ticks
        try await Task.sleep(for: .milliseconds(20))
        precondition(conversation.ticks == stoppedTicks, "Expired grace must stop further reads")
        // An extra disappear must not grant another grace period.
        sync.leave(listOwner)
        try await Task.sleep(for: .milliseconds(20))
        precondition(conversation.active == 0 && catalog.active == 0)

        sync.enter(listOwner, conversation: false)
        try await until { conversation.active == 1 && catalog.active == 1 }
        sync.setForeground(false)
        try await until { conversation.active == 0 && catalog.active == 0 }
        sync.setForeground(true)
        try await until { conversation.active == 1 && catalog.active == 1 }
        precondition(conversation.maxActive == 1 && catalog.maxActive == 1, "Resuming must never overlap old and new pollers")

        let startsBeforeReset = catalog.starts
        sync.removeAll()
        sync.register(catalogID, kind: .catalog) { await catalog.run() }
        try await until { catalog.starts == startsBeforeReset + 1 && catalog.active == 1 && conversation.active == 0 }
        precondition(catalog.maxActive == 1, "Replacing work on login changes must wait for cancelled reads to finish")
        sync.remove(catalogID)
        try await until { catalog.active == 0 }
        precondition(sync.hasVisibleOwners, "Clearing account work must not lose the navigation visibility lease")
        sync.removeAll()
        sync.leave(listOwner)
        print("PASS: continuous list/detail synchronization, exit grace, quick reentry, expiry, foreground suspension and non-overlapping pollers")
    }
}
