import Foundation

@MainActor private final class Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let ready = waiters
        waiters = []
        for waiter in ready { waiter.resume() }
    }
}

@main struct ConsoleSessionRestorationTests {
    @MainActor static func main() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expiry = ISO8601DateFormatter().string(from: now.addingTimeInterval(300))
        var validation = ConsoleSessionValidation()
        precondition(!validation.canReuse(context: "one", expiresAt: expiry, now: now), "An unvalidated session was reused")
        validation.record(context: "one", now: now)
        precondition(validation.canReuse(context: "one", expiresAt: expiry, now: now.addingTimeInterval(59)))
        precondition(!validation.canReuse(context: "one", expiresAt: expiry, now: now.addingTimeInterval(60)), "Validation cache outlived its bound")
        precondition(!validation.canReuse(context: "two", expiresAt: expiry, now: now), "Validation leaked across accounts or sessions")
        precondition(!validation.canReuse(context: "one", expiresAt: expiry, now: now.addingTimeInterval(-1)), "Clock rollback extended the cache")
        precondition(!validation.canReuse(context: "one", expiresAt: "invalid", now: now))
        precondition(!ConsoleSessionValidation.needsRefresh(expiresAt: expiry, now: now.addingTimeInterval(269)))
        precondition(ConsoleSessionValidation.needsRefresh(expiresAt: expiry, now: now.addingTimeInterval(270)))
        precondition(ConsoleSessionValidation.needsRefresh(expiresAt: expiry, now: now.addingTimeInterval(301)))
        let almostExpired = ISO8601DateFormatter().string(from: now.addingTimeInterval(30))
        precondition(!validation.canReuse(context: "one", expiresAt: almostExpired, now: now), "Expiring credentials bypassed validation")

        let restoration = ConsoleSessionRestoration()
        let started = Gate()
        let response = Gate()
        var requests = 0
        var authenticated = false

        let originalView = Task { @MainActor in
            await restoration.run {
                requests += 1
                started.open()
                await response.wait()
                precondition(!Task.isCancelled, "View cancellation cancelled session validation")
                authenticated = true
            }
        }
        await started.wait()
        originalView.cancel()

        var replacementStarted = false
        let replacementView = Task { @MainActor in
            replacementStarted = true
            await restoration.run {
                fatalError("Replacement view started duplicate validation")
            }
            precondition(authenticated, "Replacement view skipped in-flight validation")
        }
        while !replacementStarted { await Task.yield() }
        response.open()
        await originalView.value
        await replacementView.value
        precondition(authenticated && requests == 1)

        // Completing a validation must allow a later foreground entry to revalidate.
        await restoration.run { requests += 1 }
        precondition(requests == 2)

        let entry = Gate()
        let cancelledView = Task { @MainActor in
            await entry.wait()
            await restoration.run { fatalError("A cancelled view started validation") }
        }
        cancelledView.cancel()
        entry.open()
        await cancelledView.value
        precondition(requests == 2)
        print("Console session restoration tests passed")
    }
}
