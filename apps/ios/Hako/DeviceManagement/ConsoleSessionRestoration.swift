import Foundation

@MainActor final class ConsoleSessionRestoration {
    private var pending: Task<Void, Never>?

    func run(_ operation: @escaping @MainActor () async -> Void) async {
        guard !Task.isCancelled else { return }
        if let pending {
            await pending.value
            return
        }
        // View task restarts must not cancel session validation. New callers join
        // the same bounded operation instead of skipping it while the client is busy.
        let task = Task { @MainActor in await operation() }
        pending = task
        await task.value
        pending = nil
    }
}
