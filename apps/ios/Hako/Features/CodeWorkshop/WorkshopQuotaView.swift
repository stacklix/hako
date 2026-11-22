import SwiftUI

// Owned by the page rather than its lazy List cell. Scrolling the header off
// screen must neither cancel the request nor start another quota read.
@MainActor final class WorkshopQuotaState: ObservableObject {
    @Published var cached: WorkshopQuotaCacheEntry?
    @Published var identity = ""
    private var expiration: Task<Void, Never>?
    @Published var displayedAt = Date.now

    func refresh(store: WorkshopStore, agent: WorkshopAgent, clearCache: Bool) async {
        guard !Task.isCancelled else { return }
        let ticket = store.scope
        let account = store.settingsAccount + "|" + agent.id
        identity = account
        if clearCache {
            display(nil)
            do { try await store.clearCachedQuota(for: agent.id) }
            catch { HakoLog.record(.codeWorkshop, .warning, "额度缓存无法清空", detail: WorkshopSocketDiagnostics.error(error)) }
            guard !Task.isCancelled, ticket == store.scope else { return }
        }
        display(store.cachedQuota(for: agent.id))
        if cached == nil {
            let entry = await store.loadCachedQuota(for: agent.id)
            guard !Task.isCancelled, ticket == store.scope else { return }
            display(entry)
        }
        do {
            let result: WorkshopQuotaSnapshot = try await store.call(agent, "account.limits.read")
            try Task.checkCancellation()
            guard ticket == store.scope else { return }
            let entry = WorkshopQuotaCacheEntry(value: result, cachedAt: .now)
            display(entry)
            store.cacheQuota(entry, for: agent.id)
        } catch {
            if !Task.isCancelled, ticket == store.scope { display(cached) }
        }
    }

    private func display(_ entry: WorkshopQuotaCacheEntry?) {
        expiration?.cancel(); expiration = nil
        displayedAt = .now
        cached = entry?.snapshot(at: displayedAt) == nil ? nil : entry
        guard let cached else { return }
        let expiry = cached.cachedAt.addingTimeInterval(3600)
        expiration = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, expiry.timeIntervalSinceNow))) }
            catch { return }
            guard !Task.isCancelled, self?.cached?.cachedAt == cached.cachedAt else { return }
            self?.cached = nil
        }
    }

    deinit { expiration?.cancel() }
}

@MainActor struct WorkshopQuotaView: View, Equatable {
    let store: WorkshopStore
    let agent: WorkshopAgent
    @ObservedObject var state: WorkshopQuotaState
    private let scope: String
    private let stateIdentity: ObjectIdentifier

    init(store: WorkshopStore, agent: WorkshopAgent, state: WorkshopQuotaState) {
        self.store = store; self.agent = agent; self.state = state
        scope = store.scope
        stateIdentity = ObjectIdentifier(state)
    }

    nonisolated static func == (left: Self, right: Self) -> Bool {
        left.store === right.store && left.agent == right.agent && left.stateIdentity == right.stateIdentity && left.scope == right.scope
    }

    var body: some View {
        let identity = store.settingsAccount + "|" + agent.id
        let snapshot = state.identity == identity ? state.cached?.snapshot(at: state.displayedAt) : nil
        VStack(alignment: .leading, spacing: 5) {
            if let snapshot, !snapshot.buckets.isEmpty {
                ForEach(snapshot.buckets) { bucket in
                    if let window = bucket.primary { row(bucket, window: window, primary: true) }
                    if let window = bucket.secondary { row(bucket, window: window, primary: false) }
                }
            } else {
                Text("未知")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ bucket: WorkshopQuotaBucket, window: WorkshopQuotaWindow, primary: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(bucket.title + " · " + window.periodLabel(primary: primary))
                .lineLimit(1).minimumScaleFactor(0.85)
            HStack(spacing: 8) {
                Text(window.remaining(at: state.displayedAt).map { "剩余 " + $0.formatted(.number.precision(.fractionLength(0...1))) + "%" } ?? "剩余 —")
                    .fontWeight(.medium)
                Spacer(minLength: 0)
                Text(window.countdown(at: state.displayedAt))
            }
            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.85)
        }
        .accessibilityElement(children: .combine)
    }

}
