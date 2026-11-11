import Foundation

// Own read loops independently of navigation. A cancelled loop finishes before
// its replacement starts, so returning cannot create duplicate pollers.
@MainActor final class WorkshopSynchronization {
    enum Kind { case catalog, conversation }
    private struct Work {
        let kind: Kind
        let operation: @MainActor () async -> Void
    }
    private struct Running { let generation: UUID; let task: Task<Void, Never> }
    private let grace: Duration
    private let clock = ContinuousClock()
    private var owners: [UUID: Bool] = [:]
    private var work: [UUID: Work] = [:]
    private var running: [UUID: Running] = [:]
    private var deadline: ContinuousClock.Instant?
    private var expiration: Task<Void, Never>?
    private var foreground = true

    init(grace: Duration = .seconds(60)) { self.grace = grace }
    var hasVisibleOwners: Bool { !owners.isEmpty }

    func register(_ id: UUID, kind: Kind, operation: @escaping @MainActor () async -> Void) {
        guard work[id] == nil else { return }
        work[id] = Work(kind: kind, operation: operation)
        reconcile()
    }

    func remove(_ id: UUID) {
        work[id] = nil
        running[id]?.task.cancel()
    }

    func removeAll() {
        work.removeAll()
        for value in running.values { value.task.cancel() }
    }

    func enter(_ owner: UUID, conversation: Bool) {
        owners[owner] = conversation
        expiration?.cancel(); expiration = nil; deadline = nil
        reconcile()
    }

    func leave(_ owner: UUID) {
        guard owners.removeValue(forKey: owner) != nil else { return }
        if owners.isEmpty {
            let end = clock.now.advanced(by: grace)
            deadline = end
            expiration?.cancel()
            expiration = Task { [weak self, clock] in
                do { try await clock.sleep(until: end) } catch { return }
                guard let self, self.owners.isEmpty, self.deadline == end else { return }
                self.deadline = nil
                self.reconcile()
            }
        }
        reconcile()
    }

    func setForeground(_ active: Bool) { foreground = active; reconcile() }

    private func reconcile() {
        let leased = !owners.isEmpty || deadline.map { clock.now < $0 } == true
        let conversationVisible = owners.values.contains(true)
        for (id, item) in work {
            guard foreground && leased && (item.kind == .conversation || !conversationVisible) else {
                running[id]?.task.cancel()
                continue
            }
            if let current = running[id], !current.task.isCancelled { continue }
            let previous = running[id]?.task
            let generation = UUID()
            let task = Task { [weak self] in
                await previous?.value
                if !Task.isCancelled { await item.operation() }
                if self?.running[id]?.generation == generation { self?.running[id] = nil }
            }
            running[id] = Running(generation: generation, task: task)
        }
    }
}
