import SwiftUI

// Owned by the page rather than its lazy List cell. Scrolling the header off
// screen must neither cancel the request nor start another quota read.
@MainActor final class WorkshopQuotaState: ObservableObject {
    @Published var cached: WorkshopQuotaCacheEntry?
    @Published var identity = ""
    @Published private(set) var fetching = false
    private var refreshID = UUID()
    private var expiration: Task<Void, Never>?
    @Published var displayedAt = Date.now
    @Published private(set) var usage: WorkshopUsageSnapshot?
    @Published private(set) var usageIdentity = ""
    @Published private(set) var usageFetching = false
    @Published private(set) var usageError: String?
    private var usageRequest = UUID()

    func refreshUsage(store: WorkshopStore, agent: WorkshopAgent) async {
        let ticket = store.scope, identity = store.scope + "|" + agent.id
        guard !Task.isCancelled, !usageFetching || usageIdentity != identity else { return }
        let request = UUID()
        usageRequest = request
        if usageIdentity != identity { usage = nil }
        usageIdentity = identity; usageError = nil; usageFetching = true
        defer { if usageRequest == request { usageFetching = false } }
        do {
            let result = try await store.codexUsage(agent)
            guard !Task.isCancelled, ticket == store.scope, usageRequest == request else { return }
            usage = result
        } catch {
            guard !Task.isCancelled, ticket == store.scope, usageRequest == request else { return }
            usageError = error.localizedDescription
        }
    }

    func refresh(store: WorkshopStore, agent: WorkshopAgent, clearCache: Bool) async {
        guard !Task.isCancelled else { return }
        let request = UUID()
        refreshID = request
        fetching = true
        defer { if refreshID == request { fetching = false } }
        let ticket = store.scope
        let account = store.settingsAccount + "|" + agent.id
        identity = account
        if clearCache {
            display(nil)
            do { try await store.clearCachedQuota(for: agent.id) }
            catch { HakoLog.record(.codeWorkshop, .warning, "额度缓存无法清空", detail: WorkshopSocketDiagnostics.error(error)) }
            guard !Task.isCancelled, refreshID == request, ticket == store.scope else { return }
        }
        display(store.cachedQuota(for: agent.id))
        if cached == nil {
            let entry = await store.loadCachedQuota(for: agent.id)
            guard !Task.isCancelled, refreshID == request, ticket == store.scope else { return }
            display(entry)
        }
        do {
            let result: WorkshopQuotaSnapshot = try await store.call(agent, "account.limits.read")
            try Task.checkCancellation()
            guard refreshID == request, ticket == store.scope else { return }
            let entry = WorkshopQuotaCacheEntry(value: result, cachedAt: .now)
            display(entry)
            store.cacheQuota(entry, for: agent.id)
        } catch {
            if !Task.isCancelled, refreshID == request, ticket == store.scope { display(cached) }
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
