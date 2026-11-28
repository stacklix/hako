import Foundation

/// Memory belongs to the account/computer file, independently of view lifetime.
@MainActor final class WorkshopQuotaCache {
    private var entries: [URL: WorkshopQuotaCacheEntry] = [:]
    private var loaded = Set<URL>()
    private var loads: [URL: Task<WorkshopQuotaCacheEntry?, Never>] = [:]
    private var generation = UUID()
    private var revisions: [URL: UUID] = [:]

    func cached(at file: URL, now: Date = .now) -> WorkshopQuotaCacheEntry? {
        guard let entry = entries[file], entry.snapshot(at: now) != nil else { return nil }
        return entry
    }

    func load(_ file: URL, read: @escaping @Sendable () async -> WorkshopQuotaCacheEntry?) async -> WorkshopQuotaCacheEntry? {
        if loaded.contains(file) { return cached(at: file) }
        let ticket = generation
        let revision = revisions[file]
        let load: Task<WorkshopQuotaCacheEntry?, Never>
        if let existing = loads[file] { load = existing }
        else { load = Task { await read() }; loads[file] = load }
        let entry = await load.value
        guard !Task.isCancelled, ticket == generation, revision == revisions[file] else { return nil }
        loads[file] = nil; loaded.insert(file)
        // Never replace a live response that arrived during the disk read.
        if entries[file] == nil, let entry, entry.snapshot(at: .now) != nil { entries[file] = entry }
        return cached(at: file)
    }

    func store(_ entry: WorkshopQuotaCacheEntry, at file: URL) {
        entries[file] = entry; loaded.insert(file)
    }

    func remove(at file: URL) {
        revisions[file] = UUID()
        loads.removeValue(forKey: file)?.cancel()
        entries[file] = nil
        loaded.insert(file)
    }

    func reset() {
        generation = UUID()
        loads.values.forEach { $0.cancel() }; loads.removeAll()
        entries.removeAll(); loaded.removeAll()
        revisions.removeAll()
    }
}

struct WorkshopQuotaCacheEntry: Codable, Sendable {
    let value: WorkshopQuotaSnapshot
    let cachedAt: Date

    func snapshot(at now: Date) -> WorkshopQuotaSnapshot? {
        let age=now.timeIntervalSince(cachedAt)
        return age >= 0 && age < 3600 ? value : nil
    }
}

struct WorkshopQuotaSnapshot: Codable, Sendable {
    let buckets: [WorkshopQuotaBucket]
    let checkedAt: Double
    var credits: WorkshopQuotaCredits? {
        buckets.first { $0.id == "codex" }?.credits ?? buckets.compactMap(\.credits).first
    }
    var weeklyWindow: WorkshopQuotaWindow? {
        let ordered = buckets.filter { $0.id == "codex" } + buckets.filter { $0.id != "codex" }
        return ordered.flatMap { [$0.primary, $0.secondary].compactMap { $0 } }
            .first { $0.windowDurationMins == 10080 }
    }
    func remainingFraction(at now: Date) -> Double? {
        let windows = buckets.flatMap { [$0.primary, $0.secondary].compactMap { $0 } }
        let remaining = windows.compactMap { $0.remaining(at: now) }
        // The section's progress indicator represents the most restrictive reported quota.
        // An unknown/elapsed window cannot be treated as recovered capacity.
        guard !windows.isEmpty, remaining.count == windows.count, let minimum = remaining.min() else { return nil }
        return minimum / 100
    }
    var nextRefreshDelay: TimeInterval {
        let future=buckets.flatMap { [$0.primary,$0.secondary].compactMap { $0?.resetsAt } }
            .map { $0-Date.now.timeIntervalSince1970 }.filter { $0 > 0 }
        return min(60,max(1,(future.min() ?? 59)+1))
    }
    func displayBuckets(model: String?) -> [WorkshopQuotaBucket] {
        let matching=buckets.filter { !$0.model.isEmpty && $0.model == model }
        return matching.isEmpty ? buckets : buckets.filter { $0.model.isEmpty || $0.model == model }
    }
}

struct WorkshopQuotaBucket: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let model: String
    let primary: WorkshopQuotaWindow?
    let secondary: WorkshopQuotaWindow?
    var credits: WorkshopQuotaCredits? = nil
    var title: String { name.isEmpty ? (id == "codex" || id.isEmpty ? "Codex" : id) : name }
}

struct WorkshopQuotaCredits: Codable, Sendable {
    let hasCredits: Bool
    let unlimited: Bool
    let balance: String?

    var displayBalance: String {
        if unlimited { return "不限量" }
        guard let balance, balance.range(of: #"\A[0-9]+(?:\.[0-9]+)?\z"#, options: .regularExpression) != nil,
              let amount = Decimal(string: balance, locale: Locale(identifier: "en_US_POSIX")), amount >= 0 else { return "未知" }
        return String(balance.prefix { $0 != "." })
    }
}

struct WorkshopQuotaWindow: Codable, Sendable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Double?
    func remainingTimeFraction(at now: Date) -> Double? {
        guard let minutes = windowDurationMins, minutes > 0, let resetsAt, resetsAt.isFinite,
              resetsAt > 0, now.timeIntervalSince1970.isFinite else { return nil }
        return min(1, max(0, (resetsAt - now.timeIntervalSince1970) / (Double(minutes) * 60)))
    }
    var resetDate: Date? {
        guard let resetsAt, resetsAt.isFinite, (0...253402300799).contains(resetsAt) else { return nil }
        return Date(timeIntervalSince1970: resetsAt)
    }
    func remaining(at now: Date) -> Double? {
        guard usedPercent.isFinite,usedPercent >= 0, resetsAt.map({ $0 > now.timeIntervalSince1970 }) ?? true else { return nil }
        return min(100,max(0,100-usedPercent))
    }
    func periodLabel(primary: Bool) -> String {
        guard let minutes=windowDurationMins,minutes > 0 else { return primary ? "主周期" : "次周期" }
        if minutes % 10080 == 0 { return "\(minutes/10080)周" }
        if minutes % 1440 == 0 { return "\(minutes/1440)天" }
        if minutes % 60 == 0 { return "\(minutes/60)小时" }
        return "\(minutes)分钟"
    }
    func countdown(at now: Date) -> String {
        guard let resetsAt,resetsAt.isFinite else { return "重置时间未知" }
        let interval=resetsAt-now.timeIntervalSince1970
        guard interval > 0 else { return "等待刷新额度" }
        // Protect the conversion against invalid or unreasonable remote timestamps.
        guard interval < Double(Int.max/2) else { return "重置时间未知" }
        let seconds=Int(ceil(interval)),days=seconds/86400,hours=seconds/3600 % 24,minutes=seconds/60 % 60
        if days > 0 { return "\(days)天\(hours)小时后重置" }
        if hours > 0 { return "\(hours)小时\(minutes)分后重置" }
        if minutes > 0 { return "\(minutes)分\(seconds % 60)秒后重置" }
        return "\(seconds)秒后重置"
    }
}

struct WorkshopUsageSnapshot: Decodable, Sendable {
    let available: Bool
    let collectedAt: String
    let timeZone: String
    let days: [WorkshopUsageDay]
    let warnings: [String]
    let requestCountKind: String
    var countsUserMessages: Bool { requestCountKind == "user_messages" }
    var totalTokens: Int64? { Self.sum(days.map(\.totalTokens)) }
    var totalRequests: Int64? { Self.sum(days.map(\.requestCount)) }
    var isValid: Bool {
        days.count == 7 && Set(days.map(\.date)).count == 7 && days.allSatisfy(\.isValid)
            && days.map(\.date) == days.map(\.date).sorted() && totalTokens != nil && totalRequests != nil
    }
    private static func sum(_ values: [Int64]) -> Int64? {
        var total: Int64 = 0
        for value in values {
            let next = total.addingReportingOverflow(value)
            guard !next.overflow else { return nil }
            total = next.partialValue
        }
        return total
    }
}

struct WorkshopUsageDay: Decodable, Identifiable, Sendable {
    let date: String
    let requestCount: Int64
    let inputTokens: Int64
    let cachedInputTokens: Int64
    let outputTokens: Int64
    let reasoningOutputTokens: Int64
    let totalTokens: Int64
    let breakdownAvailable: Bool
    var id: String { date }
    var shortDate: String { String(date.suffix(5)).replacingOccurrences(of: "-", with: ".") }
    var isValid: Bool {
        date.range(of: "\\A[0-9]{4}-[0-9]{2}-[0-9]{2}\\z", options: .regularExpression) != nil
            && requestCount >= 0 && inputTokens >= 0 && cachedInputTokens >= 0 && outputTokens >= 0
            && reasoningOutputTokens >= 0 && totalTokens >= 0
            && (!breakdownAvailable || (cachedInputTokens <= inputTokens && reasoningOutputTokens <= outputTokens
                && inputTokens <= Int64.max - outputTokens && totalTokens == inputTokens + outputTokens))
    }
}
