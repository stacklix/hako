import Foundation

@MainActor private final class Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let waiting = waiters; waiters.removeAll()
        for waiter in waiting { waiter.resume() }
    }
}

@main struct HakoPresentationQueueTests {
    @MainActor static func main() async {
        await newestRequestWaitsForThePreviousTransition()
        await cancellingKeepsOwnershipUntilUIKitCompletes()
        await requestsBeforeTheHostStartsKeepOnlyTheNewest()
        await navigationWaitsForSheetDismissal()
        print("PASS: serialized modal transitions, newest notification wins, stale callback rejection, cancellation ownership, deferred host and dismissal-before-navigation")
    }

    @MainActor static func newestRequestWaitsForThePreviousTransition() async {
        let started = Gate(), animation = Gate(), finished = Gate()
        var active = 0, maximum = 0
        var events: [String] = []
        let queue = HakoPresentationQueue<String> { request, isCurrent in
            active += 1; maximum = max(maximum, active)
            events.append("start:" + request)
            if request == "pinned-session" { started.open(); await animation.wait() }
            if isCurrent() { events.append("commit:" + request) }
            active -= 1
            if request == "latest-notice" { finished.open() }
        }
        queue.submit("pinned-session")
        await started.wait()
        queue.submit("older-notice")
        queue.submit("latest-notice")
        precondition(events == ["start:pinned-session"] && active == 1)
        animation.open()
        await finished.wait()
        precondition(maximum == 1, "An in-flight UIKit transition must own presentation until its completion")
        precondition(events == ["start:pinned-session", "start:latest-notice", "commit:latest-notice"],
                     "An old completion must not overwrite the latest notification, and superseded pending notices must not open")
        precondition(!queue.isBusy)
    }

    @MainActor static func cancellingKeepsOwnershipUntilUIKitCompletes() async {
        let started = Gate(), animation = Gate(), finished = Gate()
        var active = 0, commits: [String] = []
        let queue = HakoPresentationQueue<String> { request, isCurrent in
            active += 1
            precondition(active == 1)
            if request == "old-window" { started.open(); await animation.wait() }
            if isCurrent() { commits.append(request) }
            active -= 1
            if request == "new-window" { finished.open() }
        }
        queue.submit("old-window")
        await started.wait()
        queue.submit("discarded")
        queue.cancel()
        queue.submit("new-window")
        precondition(queue.isBusy && commits.isEmpty)
        animation.open()
        await finished.wait()
        precondition(commits == ["new-window"] && !queue.isBusy,
                     "Changing window must discard stale callbacks without overlapping two active transitions")
    }

    @MainActor static func requestsBeforeTheHostStartsKeepOnlyTheNewest() async {
        let finished = Gate()
        var opened: [Int] = []
        let queue = HakoPresentationQueue<Int> { value, isCurrent in
            if isCurrent() { opened.append(value) }
            finished.open()
        }
        queue.submit(1); queue.submit(2); queue.submit(3)
        await finished.wait()
        precondition(opened == [3] && !queue.isBusy, "Cold-start duplicate requests must select the most recent destination")
    }

    @MainActor static func navigationWaitsForSheetDismissal() async {
        let dismissalStarted = Gate(), dismissed = Gate(), finished = Gate()
        var events: [String] = []
        let queue = HakoPresentationQueue<String> { request, isCurrent in
            events.append("dismiss-start:" + request)
            dismissalStarted.open()
            await dismissed.wait()
            events.append("dismiss-complete:" + request)
            if isCurrent() { events.append("replace-navigation:" + request) }
            if request == "second" { finished.open() }
        }
        queue.submit("first")
        await dismissalStarted.wait()
        precondition(events == ["dismiss-start:first"], "Do not reset the SwiftUI stack while a native sheet owns it")
        queue.submit("second")
        dismissed.open()
        await finished.wait()
        precondition(events == ["dismiss-start:first", "dismiss-complete:first", "dismiss-start:second", "dismiss-complete:second", "replace-navigation:second"])
    }
}
