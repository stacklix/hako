import Foundation

/// UIKit transitions must finish before another owner presents or replaces navigation.
@MainActor
final class HakoPresentationQueue<Value> {
    typealias Handler = @MainActor (Value, @escaping @MainActor () -> Bool) async -> Void
    private let handler: Handler
    private var pending: (id: UUID, value: Value)?
    private var latest: UUID?
    private var worker: Task<Void, Never>?
    var isBusy: Bool { worker != nil }

    init(handler: @escaping Handler) { self.handler = handler }

    func submit(_ value: Value) {
        let id = UUID()
        latest = id; pending = (id, value)
        guard worker == nil else { return }
        worker = Task { [weak self] in await self?.drain() }
    }

    func cancel() {
        latest = nil; pending = nil
        // A cancelled request still owns its in-flight UIKit completion.
        // Do not start the next request until that completion has returned.
    }

    private func drain() async {
        while let request = pending {
            pending = nil
            await handler(request.value, { [weak self] in self?.latest == request.id })
        }
        worker = nil
    }
}
