import SwiftUI

@MainActor private final class WorkshopQuotaState: ObservableObject {
    @Published var cached: WorkshopQuotaCacheEntry?
    var identity = ""
    @Published var failed = false
}

@MainActor struct WorkshopQuotaView: View, Equatable {
    let store: WorkshopStore
    let agent: WorkshopAgent
    let active: Bool
    private let scope: String
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var state = WorkshopQuotaState()
    @State private var retry=0

    init(store: WorkshopStore, agent: WorkshopAgent, active: Bool) {
        self.store=store;self.agent=agent;self.active=active
        scope = store.scope
    }

    nonisolated static func == (left: Self, right: Self) -> Bool {
        left.store === right.store && left.agent == right.agent && left.active == right.active && left.scope == right.scope
    }

    private var identity: String { store.settingsAccount+"|"+agent.id }

    var body: some View {
        let snapshot = state.identity == identity ? state.cached?.snapshot(at: .now) : nil
        VStack(alignment:.leading,spacing:5) {
            if let snapshot,!snapshot.buckets.isEmpty {
                VStack(alignment:.leading,spacing:5) {
                    ForEach(snapshot.buckets) { bucket in
                        if let window=bucket.primary { row(bucket,window:window,primary:true) }
                        if let window=bucket.secondary { row(bucket,window:window,primary:false) }
                    }
                }
                if state.failed { retryButton("额度未更新 · 点击重试") }
            } else {
                if state.failed { retryButton("Codex 额度暂不可用 · 点击重试") }
                else { Text(snapshot == nil ? "正在读取 Codex 额度…" : "Codex 未返回额度数据") }
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .frame(maxWidth:.infinity,alignment:.leading)
        .task(id: state.cached?.cachedAt) {
            guard let entry = state.cached else { return }
            while entry.snapshot(at: .now) != nil {
                let remaining = max(0.001, entry.cachedAt.addingTimeInterval(3600).timeIntervalSinceNow)
                do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            }
            if state.cached?.cachedAt == entry.cachedAt { state.cached = nil }
        }
        .task(id:store.scope+"|"+agent.id+"|"+String(describing:scenePhase)+"|\(active)|\(retry)") {
            let ticket = identity
            if state.identity != ticket {
                state.cached = nil; state.identity = ticket
            }
            if state.cached?.snapshot(at: .now) == nil {
                state.cached = store.cachedQuota(for: agent.id)
                if state.cached == nil {
                    let entry = await store.loadCachedQuota(for: agent.id)
                    guard !Task.isCancelled, identity == ticket else { return }
                    state.cached = entry
                }
            }
            if state.failed { state.failed = false }
            guard active,scenePhase == .active else { return }
            while !Task.isCancelled {
                do {
                    let result: WorkshopQuotaSnapshot = try await store.call(agent,"account.limits.read")
                    try Task.checkCancellation()
                    guard identity == ticket else { return }
                    let entry=WorkshopQuotaCacheEntry(value:result,cachedAt:.now)
                    state.cached = entry
                    if state.failed { state.failed = false }
                    store.cacheQuota(entry,for:agent.id)
                } catch {
                    if Task.isCancelled { return }
                    if !state.failed { state.failed = true }
                }
                do { try await Task.sleep(for:.seconds(state.cached?.snapshot(at:.now)?.nextRefreshDelay ?? 60)) }
                catch { return }
            }
        }
    }

    private func row(_ bucket: WorkshopQuotaBucket,window: WorkshopQuotaWindow,primary: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(bucket.title + " · " + window.periodLabel(primary: primary))
                .lineLimit(1).minimumScaleFactor(0.85)
            WorkshopQuotaReadout(window: window, active: active && scenePhase == .active)
        }
        .accessibilityElement(children:.combine)
    }
    private func retryButton(_ title: String) -> some View {
        Button(title) { retry += 1 }.buttonStyle(.plain).accessibilityLabel("重新读取 Codex 账号额度")
    }
}

private struct WorkshopQuotaReadout: View {
    let window: WorkshopQuotaWindow
    let active: Bool

    var body: some View {
        Group {
            if active {
                TimelineView(.periodic(from: .now, by: 1)) { context in readout(at: context.date) }
            } else {
                readout(at: .now)
            }
        }
    }

    private func readout(at date: Date) -> some View {
        HStack(spacing: 8) {
            Text(window.remaining(at: date).map { "剩余 " + $0.formatted(.number.precision(.fractionLength(0...1))) + "%" } ?? "剩余 —")
                .fontWeight(.medium)
            Spacer(minLength: 0)
            Text(window.countdown(at: date))
        }
        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.85)
    }
}
