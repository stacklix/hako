import Foundation

private enum BatchContext { @TaskLocal static var reason: String? }

@MainActor private final class BatchProbe {
    var active = 0
    var maximum = 0
    var started = 0
    var released = false
    var timedOut = false
    var starts: [CheckedContinuation<Void, Never>] = []
    var waits: [CheckedContinuation<Void, Never>] = []
    func run(_ input: Int) async throws -> Int {
        active += 1; started += 1; maximum = max(maximum, active)
        defer { active -= 1 }
        precondition(BatchContext.reason == "shortcut", "Child reads must retain diagnostics context")
        if started == 3 { starts.forEach { $0.resume() }; starts.removeAll() }
        if !released { await withCheckedContinuation { waits.append($0) } }
        try Task.checkCancellation()
        return input * 2
    }
    func waitForFirstWave() async {
        if started < 3 { await withCheckedContinuation { starts.append($0) } }
    }
    func release(timedOut: Bool = false) {
        self.timedOut = timedOut; released = true
        starts.forEach { $0.resume() }; starts.removeAll()
        waits.forEach { $0.resume() }; waits.removeAll()
    }
}

@main struct InvestmentQuoteBatchTests {
    @MainActor static func main() async throws {
        let probe = BatchProbe()
        let batch = Task {
            try await BatchContext.$reason.withValue("shortcut") {
                try await InvestmentQuoteBatch.map(Array(0..<12)) { try await probe.run($0) }
            }
        }
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { probe.release(timedOut: true) }
        }
        await probe.waitForFirstWave()
        precondition(!probe.timedOut && probe.started == 3, "Three reads must overlap before any response")
        probe.release(); watchdog.cancel()
        let values = try await batch.value
        precondition(values == Array(0..<12).map { $0 * 2 } && probe.maximum == 3 && probe.active == 0)
        let channels = [BatchProbe(), BatchProbe()]
        let independent = Task {
            try await BatchContext.$reason.withValue("shortcut") {
                try await InvestmentQuoteBatch.map(Array(0..<12), channel: { $0 < 6 ? "twelveData" : "eastmoney" }) { input in
                    try await channels[input < 6 ? 0 : 1].run(input)
                }
            }
        }
        let independentWatchdog = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { channels.forEach { $0.release(timedOut: true) } }
        }
        for channel in channels { await channel.waitForFirstWave() }
        precondition(channels.allSatisfy { $0.started == 3 && !$0.timedOut } && channels.reduce(0) { $0 + $1.active } == 6,
                     "Each channel needs its own three slots, even when inputs of another channel come first")
        channels.forEach { $0.release() }; independentWatchdog.cancel()
        let independentValues = try await independent.value
        precondition(independentValues == Array(0..<12).map { $0 * 2 } && channels.allSatisfy { $0.maximum == 3 && $0.active == 0 })
        let reversed = try await InvestmentQuoteBatch.map(Array(0..<6)) { input in
            try await Task.sleep(for: .milliseconds((6 - input) * 3))
            return input
        }
        precondition(reversed == Array(0..<6), "Out-of-order completions must preserve input/result association")
        let empty: [Int] = try await InvestmentQuoteBatch.map([Int]()) { $0 }
        precondition(empty.isEmpty)

        enum Failed: Error { case read }
        var published = false
        do {
            _ = try await InvestmentQuoteBatch.map(Array(0..<8)) { input in
                if input == 0 { throw Failed.read }
                try await Task.sleep(for: .seconds(30))
                return input
            }
            published = true
            preconditionFailure("A failed batch must not publish partial results")
        } catch Failed.read { }
        precondition(!published)

        let cancellation = BatchProbe()
        let cancelled = Task {
            try await BatchContext.$reason.withValue("shortcut") {
                try await InvestmentQuoteBatch.map(Array(0..<9)) { input in
                    _ = try await cancellation.run(input)
                    try await Task.sleep(for: .seconds(30))
                    return input
                }
            }
        }
        let cancelWatchdog = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { cancellation.release(timedOut: true) }
        }
        await cancellation.waitForFirstWave()
        cancelled.cancel(); cancellation.release(); cancelWatchdog.cancel()
        do { _ = try await cancelled.value; preconditionFailure("Cancelled batch returned results") }
        catch is CancellationError { }
        precondition(!cancellation.timedOut && cancellation.started == 3 && cancellation.active == 0,
                     "Cancellation must stop queued work and finish active children")
        print("PASS: independent channel concurrency limits, overlapping quote reads, stable result ordering, task-local context, failure and cancellation")
    }
}
