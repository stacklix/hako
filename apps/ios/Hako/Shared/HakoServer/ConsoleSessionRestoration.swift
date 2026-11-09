import Foundation

struct ConsoleSessionValidation {
    private var context: String?
    private var validatedAt: Date?

    static func needsRefresh(expiresAt: String, now: Date = .now) -> Bool {
        guard let expiry = ISO8601DateFormatter().date(from: expiresAt) else { return true }
        return expiry.timeIntervalSince(now) <= 30
    }

    func canReuse(context: String, expiresAt: String, now: Date = .now) -> Bool {
        guard self.context == context, let validatedAt,
              now >= validatedAt, now.timeIntervalSince(validatedAt) < 60 else { return false }
        return !Self.needsRefresh(expiresAt: expiresAt, now: now)
    }

    mutating func record(context: String, now: Date = .now) {
        self.context = context
        validatedAt = now
    }
}

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
