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
        precondition(snapshot.credits == nil, "An absent balance must not be inferred from remaining percent")
        let creditData = Data(#"{"checkedAt":1800000000,"buckets":[{"id":"codex","name":"","model":"","primary":null,"secondary":null,"credits":{"hasCredits":true,"unlimited":false,"balance":"123.45"}}]}"#.utf8)
        let creditsSnapshot = try JSONDecoder().decode(WorkshopQuotaSnapshot.self, from: creditData)
        precondition(creditsSnapshot.credits?.displayBalance == "123")
        let storedCredits = try JSONDecoder().decode(WorkshopQuotaSnapshot.self, from: JSONEncoder().encode(creditsSnapshot))
        precondition(storedCredits.credits?.balance == "123.45", "Cached quota must retain the reported credit balance")
        precondition(storedCredits.credits?.displayBalance == "123")
        precondition(WorkshopQuotaCredits(hasCredits: true, unlimited: false, balance: "60801.7583680000").displayBalance == "60801")
        precondition(WorkshopQuotaCredits(hasCredits: true, unlimited: false, balance: "1.999").displayBalance == "1", "Display discards fractions without rounding up the remaining credits")
        precondition(WorkshopQuotaCredits(hasCredits: true, unlimited: true, balance: nil).displayBalance == "不限量")
        precondition(WorkshopQuotaCredits(hasCredits: false, unlimited: false, balance: "0").displayBalance == "0")
        precondition(WorkshopQuotaCredits(hasCredits: false, unlimited: false, balance: nil).displayBalance == "未知")
        for invalidBalance in ["-1", "NaN", "", "1e999", "private-token"] {
            precondition(WorkshopQuotaCredits(hasCredits: true, unlimited: false, balance: invalidBalance).displayBalance == "未知")
        }
        precondition(snapshot.remainingFraction(at: now) == 0.725, "Section fill uses the least remaining reported quota, not an average")
        precondition(snapshot.remainingFraction(at: now.addingTimeInterval(3661)) == nil,
            "An elapsed window must not display an apparently healthy section fill from other windows")
        let exhausted = WorkshopQuotaWindow(usedPercent: 100, windowDurationMins: 10080, resetsAt: nil)
        let full = WorkshopQuotaWindow(usedPercent: 0, windowDurationMins: 300, resetsAt: nil)
        let limited = WorkshopQuotaSnapshot(buckets: [.init(id:"codex", name:"", model:"", primary:full, secondary:exhausted)], checkedAt:0)
        precondition(limited.remainingFraction(at: now) == 0, "An exhausted secondary window empties the whole-section fill")
        precondition(WorkshopQuotaSnapshot(buckets: [.init(id:"codex", name:"", model:"", primary:full, secondary:nil)], checkedAt:0).remainingFraction(at:now) == 1)
        precondition(WorkshopQuotaSnapshot(buckets: [], checkedAt:0).remainingFraction(at:now) == nil, "Missing quota has no fill")
        let invalid = WorkshopQuotaWindow(usedPercent:Double.nan, windowDurationMins:300, resetsAt:nil)
        precondition(WorkshopQuotaSnapshot(buckets: [.init(id:"codex", name:"", model:"", primary:invalid, secondary:full)], checkedAt:0).remainingFraction(at:now) == nil,
            "A valid peer window cannot hide an invalid quota")
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
        let clearingGate = QuotaReadGate()
        let clearingFile = URL(fileURLWithPath: "/account-a/clearing-cache.json")
        let clearing = Task { await memory.load(clearingFile) { await clearingGate.read() } }
        await clearingGate.waitForRead()
        memory.remove(at: clearingFile)
        await clearingGate.finish(live)
        let cleared = await clearing.value
        precondition(cleared == nil && memory.cached(at: clearingFile) == nil,
            "Clearing quota must fence a disk read already in flight")
        _ = await memory.load(clearingFile) { preconditionFailure("Cleared data must not be loaded again") }
        precondition(memory.cached(at: otherAccount)?.cachedAt == live.cachedAt,
            "Clearing one computer must preserve other quota caches")
        memory.store(live, at: clearingFile)
        precondition(memory.cached(at: clearingFile)?.cachedAt == live.cachedAt)
        let resetGate = QuotaReadGate()
        let stale = Task { await memory.load(URL(fileURLWithPath: "/old-account/cache.json")) { await resetGate.read() } }
        await resetGate.waitForRead()
        memory.reset()
        await resetGate.finish(live)
        let staleResult = await stale.value
        precondition(staleResult == nil && memory.cached(at: computerA) == nil,
            "Account changes must fence reads already in flight and clear old memory")
        let week = WorkshopQuotaWindow(usedPercent: 68, windowDurationMins: 10080,
            resetsAt: now.timeIntervalSince1970 + 107 * 3600)
        let weekly = WorkshopQuotaSnapshot(buckets: [.init(id: "codex", name: "", model: "", primary: window, secondary: week)], checkedAt: 0)
        precondition(weekly.weeklyWindow?.remaining(at: now) == 32)
        precondition(abs(week.remainingTimeFraction(at: now)! - 107.0 / 168) < 0.000001)
        precondition(week.remainingTimeFraction(at: now.addingTimeInterval(108 * 3600)) == 0)
        precondition(weekly.weeklyWindow?.remaining(at: now.addingTimeInterval(108 * 3600)) == nil,
            "Passing reset time does not establish recovered token capacity")
        precondition(unknown.remainingTimeFraction(at: now) == nil)
        precondition(WorkshopQuotaWindow(usedPercent: 0, windowDurationMins: 10080, resetsAt: .infinity).resetDate == nil)
        precondition(WorkshopQuotaSnapshot(buckets: [.init(id: "codex", name: "", model: "", primary: window, secondary: nil)], checkedAt: 0).weeklyWindow == nil,
            "A five-hour quota must not be drawn as a weekly countdown")
        let anotherWeek = WorkshopQuotaWindow(usedPercent: 5, windowDurationMins: 10080, resetsAt: week.resetsAt)
        let multiple = WorkshopQuotaSnapshot(buckets: [.init(id: "model", name: "", model: "other", primary: anotherWeek, secondary: nil)] + weekly.buckets, checkedAt: 0)
        precondition(multiple.weeklyWindow?.usedPercent == 68, "The Codex account window takes priority over a model-specific bucket")
        let days: [[String: Any]] = (20...26).map { day in
            ["date": "2026-11-\(day)", "requestCount": 2, "inputTokens": 80, "cachedInputTokens": 60,
             "outputTokens": 20, "reasoningOutputTokens": 5, "totalTokens": 100, "breakdownAvailable": true]
        }
        func usage(_ values: [[String: Any]]) throws -> WorkshopUsageSnapshot {
            let payload: [String: Any] = ["available": true, "collectedAt": "2026-11-26T12:00:00Z",
                "timeZone": "China Standard Time", "days": values, "warnings": [], "requestCountKind": "user_messages"]
            return try JSONDecoder().decode(WorkshopUsageSnapshot.self, from: JSONSerialization.data(withJSONObject: payload))
        }
        let statistics = try usage(days)
        precondition(statistics.isValid && statistics.totalTokens == 700 && statistics.totalRequests == 14,
            "Cache input and reasoning output must not be counted twice")
        precondition(statistics.countsUserMessages && statistics.days.last?.shortDate == "11.26")
        let duplicateDays = try usage(days + [days[0]])
        precondition(!duplicateDays.isValid, "Duplicate days must not inflate totals")
        var invalidDays = days
        invalidDays[0]["requestCount"] = -1
        let negativeCounts = try usage(invalidDays)
        precondition(!negativeCounts.isValid)
        invalidDays = days
        invalidDays[0]["totalTokens"] = Int64.max
        invalidDays[0]["breakdownAvailable"] = false
        let overflowing = try usage(invalidDays)
        precondition(!overflowing.isValid, "Overflowing totals cannot appear as a healthy usage summary")
        print("Workshop quota: weekly rings, reset boundaries, real daily totals, invalid data and isolated cache passed")
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
