import Foundation

// A replacement reader waits for a cancelled request to release its slot, then loads again.
@MainActor final class QinglongRefreshCoordinator {
    private var requests: [QinglongResource: UUID] = [:]
    private var waiters: [UUID: [UUID: CheckedContinuation<Bool, Never>]] = [:]

    func run(_ resource: QinglongResource, operation: () async -> Void) async {
        while let ticket = requests[resource] {
            let completed = await wait(for: ticket)
            guard !Task.isCancelled else { return }
            if completed { return }
        }
        guard !Task.isCancelled else { return }
        let ticket = UUID()
        requests[resource] = ticket
        await operation()
        if requests[resource] == ticket { requests[resource] = nil }
        let pending = waiters.removeValue(forKey: ticket) ?? [:]
        for continuation in pending.values { continuation.resume(returning: !Task.isCancelled) }
    }

    func invalidate() {
        requests = [:]
        let pending = waiters.values.flatMap { $0.values }
        waiters = [:]
        for continuation in pending { continuation.resume(returning: false) }
    }

    private func wait(for ticket: UUID) async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: false); return }
                waiters[ticket, default: [:]][id] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.waiters[ticket]?.removeValue(forKey: id)?.resume(returning: false)
            }
        }
    }
}
