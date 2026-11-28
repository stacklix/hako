import Foundation

@main struct StartupPerformanceTests {
    enum Failure: Error { case expected }

    @MainActor static func main() async throws {
        let preparation = HakoBackupPreparation()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let secondEntered = DispatchSemaphore(value: 0)
        let first = Task { @MainActor in
            try await preparation.run {
                precondition(!Thread.isMainThread, "Backup traversal ran on the UI thread")
                entered.signal()
                precondition(release.wait(timeout: .now() + 5) == .success, "UI could not release a stalled backup operation")
            }
        }
        let started = await Task.detached { entered.wait(timeout: .now() + 2) == .success }.value
        precondition(started)
        // This actor hop must complete while filesystem work is still blocked.
        let responsive = Task { @MainActor in true }
        let didRespond = await responsive.value
        precondition(didRespond)
        let second = Task { @MainActor in
            try await preparation.run { secondEntered.signal() }
        }
        let overlapped = await Task.detached { secondEntered.wait(timeout: .now() + 0.1) == .success }.value
        precondition(!overlapped, "Backup changes overlapped instead of preserving their order")
        release.signal()
        try await first.value
        try await second.value
        precondition(secondEntered.wait(timeout: .now() + 1) == .success)
        do {
            try await preparation.run { throw Failure.expected }
            preconditionFailure("Backup errors were swallowed")
        } catch Failure.expected { }
        try await preparation.run { }
        print("PASS: blocked backup work leaves the UI actor responsive, writes stay serial, and failures permit retry")
    }
}
