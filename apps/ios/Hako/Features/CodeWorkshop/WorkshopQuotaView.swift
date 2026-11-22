import SwiftUI

@MainActor struct WorkshopQuotaView: View {
    @ObservedObject var store: WorkshopStore
    let agent: WorkshopAgent
    let active: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var cached: WorkshopQuotaCacheEntry?
    @State private var cacheIdentity = ""
    @State private var failed=false
    @State private var retry=0

    init(store: WorkshopStore, agent: WorkshopAgent, active: Bool) {
        self.store=store;self.agent=agent;self.active=active
        _cached=State(initialValue:store.cachedQuota(for:agent.id))
        _cacheIdentity=State(initialValue:store.settingsAccount+"|"+agent.id)
    }

    private var identity: String { store.settingsAccount+"|"+agent.id }

    var body: some View {
        TimelineView(.periodic(from:.now,by:1)) { context in
            let snapshot = cacheIdentity == identity ? cached?.snapshot(at:context.date) : nil
            VStack(alignment:.leading,spacing:5) {
                if let snapshot,!snapshot.buckets.isEmpty {
                    VStack(alignment:.leading,spacing:5) {
                        ForEach(snapshot.buckets) { bucket in
                            if let window=bucket.primary { row(bucket,window:window,primary:true,now:context.date) }
                            if let window=bucket.secondary { row(bucket,window:window,primary:false,now:context.date) }
                        }
                    }
                    if failed { retryButton("额度未更新 · 点击重试") }
                } else {
                    if failed { retryButton("Codex 额度暂不可用 · 点击重试") }
                    else { Text(snapshot == nil ? "正在读取 Codex 额度…" : "Codex 未返回额度数据") }
                }
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .frame(maxWidth:.infinity,alignment:.leading)
        .task(id:store.scope+"|"+agent.id+"|"+String(describing:scenePhase)+"|\(active)|\(retry)") {
            if cacheIdentity != identity {
                cached=nil;cacheIdentity=identity
            }
            if cached?.snapshot(at:.now) == nil { cached=store.cachedQuota(for:agent.id) }
            failed=false
            guard active,scenePhase == .active else { return }
            while !Task.isCancelled {
                do {
                    let result: WorkshopQuotaSnapshot = try await store.call(agent,"account.limits.read")
                    try Task.checkCancellation()
                    let entry=WorkshopQuotaCacheEntry(value:result,cachedAt:.now)
                    cached=entry;failed=false
                    store.cacheQuota(entry,for:agent.id)
                } catch {
                    if Task.isCancelled { return }
                    failed=true
                }
                do { try await Task.sleep(for:.seconds(cached?.snapshot(at:.now)?.nextRefreshDelay ?? 60)) }
                catch { return }
            }
        }
    }

    private func row(_ bucket: WorkshopQuotaBucket,window: WorkshopQuotaWindow,primary: Bool,now: Date) -> some View {
        ViewThatFits(in:.horizontal) {
            HStack(spacing:8) {
                Text(bucket.title+" · "+window.periodLabel(primary:primary))
                remaining(window,now:now)
                Spacer(minLength:0)
                Text(window.countdown(at:now)).monospacedDigit()
            }
            VStack(alignment:.leading,spacing:3) {
                HStack { Text(bucket.title+" · "+window.periodLabel(primary:primary));remaining(window,now:now) }
                Text(window.countdown(at:now)).monospacedDigit()
            }
        }
        .accessibilityElement(children:.combine)
    }
    private func remaining(_ window: WorkshopQuotaWindow,now: Date) -> some View {
        Text(window.remaining(at:now).map { "剩余 "+$0.formatted(.number.precision(.fractionLength(0...1)))+"%" } ?? "剩余 —")
            .fontWeight(.medium).monospacedDigit()
    }
    private func retryButton(_ title: String) -> some View {
        Button(title) { retry += 1 }.buttonStyle(.plain).accessibilityLabel("重新读取 Codex 账号额度")
    }
}
