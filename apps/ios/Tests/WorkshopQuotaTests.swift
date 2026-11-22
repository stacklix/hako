import Foundation

@main struct WorkshopQuotaTests {
    @MainActor static func main() async throws {
        let now=Date(timeIntervalSince1970:1_800_000_000)
        let window=WorkshopQuotaWindow(usedPercent:27.5,windowDurationMins:300,resetsAt:now.timeIntervalSince1970+3661)
        precondition(window.remaining(at:now) == 72.5 && window.periodLabel(primary:true) == "5小时")
        precondition(window.countdown(at:now) == "1小时1分后重置")
        precondition(window.countdown(at:now.addingTimeInterval(3660)) == "1秒后重置")
        precondition(window.remaining(at:now.addingTimeInterval(3661)) == nil,"an elapsed timer does not prove quota recovery")
        precondition(window.countdown(at:now.addingTimeInterval(3661)) == "等待刷新额度")
        let unknown=WorkshopQuotaWindow(usedPercent:0,windowDurationMins:nil,resetsAt:nil)
        precondition(unknown.periodLabel(primary:false) == "次周期" && unknown.countdown(at:now) == "重置时间未知")
        precondition(WorkshopQuotaWindow(usedPercent:120,windowDurationMins:10080,resetsAt:nil).remaining(at:now) == 0)
        precondition(WorkshopQuotaWindow(usedPercent: -1,windowDurationMins:60,resetsAt:nil).remaining(at:now) == nil)
        precondition(WorkshopQuotaWindow(usedPercent:Double.nan,windowDurationMins:60,resetsAt:nil).remaining(at:now) == nil)
        precondition(WorkshopQuotaWindow(usedPercent:1,windowDurationMins:10080,resetsAt:nil).periodLabel(primary:false) == "1周")
        let data=Data(#"{"checkedAt":1800000000,"buckets":[{"id":"codex","name":"","model":"","primary":{"usedPercent":27.5,"windowDurationMins":300,"resetsAt":1800003661},"secondary":null},{"id":"other","name":"Other model","model":"other-model","primary":null,"secondary":{"usedPercent":1,"windowDurationMins":10080,"resetsAt":null}}]}"#.utf8)
        let snapshot=try JSONDecoder().decode(WorkshopQuotaSnapshot.self,from:data)
        precondition(snapshot.buckets[0].title == "Codex" && snapshot.buckets[1].title == "Other model")
        precondition(snapshot.displayBuckets(model:"other-model").map(\.id) == ["codex","other"],"model quota must not hide shared account quota")
        precondition(snapshot.displayBuckets(model:"unmetered-model").count == 2)
        let entry=WorkshopQuotaCacheEntry(value:snapshot,cachedAt:now)
        precondition(entry.snapshot(at:now)?.buckets[0].primary?.usedPercent == 27.5)
        precondition(entry.snapshot(at:now.addingTimeInterval(3599.999)) != nil,"keep the last response while refreshing within one hour")
        precondition(entry.snapshot(at:now.addingTimeInterval(3600)) == nil,"expire at exactly one hour even if refresh is still running")
        precondition(entry.snapshot(at:now.addingTimeInterval(-1)) == nil,"a clock rollback cannot extend the cache")
        let reopened=try JSONDecoder().decode(WorkshopQuotaCacheEntry.self,from:JSONEncoder().encode(entry))
        precondition(reopened.snapshot(at:now.addingTimeInterval(1800))?.buckets[0].primary?.usedPercent == 27.5,"reopening preserves the last successful response")
        precondition(reopened.snapshot(at:now.addingTimeInterval(3601)) == nil,"reading persisted data must not renew its lifetime")
        precondition(reopened.cachedAt == now,"failed refreshes do not update the successful fetch time")
        let refreshed=WorkshopQuotaCacheEntry(value:snapshot,cachedAt:now.addingTimeInterval(3600))
        precondition(refreshed.snapshot(at:now.addingTimeInterval(3601)) != nil,"only a successful new response renews the cache")
        let memory = WorkshopQuotaCache()
        let computerA = URL(fileURLWithPath: "/account-a/computer-a.json")
        let computerB = URL(fileURLWithPath: "/account-a/computer-b.json")
        let otherAccount = URL(fileURLWithPath: "/account-b/computer-a.json")
        let live = WorkshopQuotaCacheEntry(value: snapshot, cachedAt: .now)
        let first = await memory.load(computerA) { live }
        precondition(first?.cachedAt == live.cachedAt)
        let reused = await memory.load(computerA) { preconditionFailure("View recreation must not reread quota from disk") }
        precondition(reused?.cachedAt == live.cachedAt)
        precondition(memory.cached(at: computerB) == nil && memory.cached(at: otherAccount) == nil,
            "Quota memory must be isolated by account and computer")
        _ = await memory.load(computerB) { nil }
        _ = await memory.load(computerB) { preconditionFailure("A missing cache must also be loaded only once") }
        let gate = QuotaReadGate()
        let loading = Task { await memory.load(otherAccount) { await gate.read() } }
        await gate.waitForRead()
        memory.store(live, at: otherAccount)
        await gate.finish(entry)
        let resolved = await loading.value
        precondition(resolved?.cachedAt == live.cachedAt, "A late disk response must not replace fresher network quota")
        let resetGate = QuotaReadGate()
        let stale = Task { await memory.load(URL(fileURLWithPath: "/old-account/cache.json")) { await resetGate.read() } }
        await resetGate.waitForRead()
        memory.reset()
        await resetGate.finish(live)
        let staleResult = await stale.value
        precondition(staleResult == nil && memory.cached(at: computerA) == nil,
            "Account changes must fence reads already in flight and clear old memory")
        print("Workshop quota: decoding, countdown, invalid values, persisted cache and strict one-hour expiration passed")
    }
}

private actor QuotaReadGate {
    private var readContinuation: CheckedContinuation<WorkshopQuotaCacheEntry?, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func read() async -> WorkshopQuotaCacheEntry? {
        await withCheckedContinuation { continuation in
            readContinuation = continuation
            started?.resume(); started = nil
        }
    }
    func waitForRead() async {
        if readContinuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish(_ entry: WorkshopQuotaCacheEntry) { readContinuation?.resume(returning: entry); readContinuation = nil }
}
