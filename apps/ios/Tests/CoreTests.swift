import Foundation
import SwiftData

@main struct CoreTests {
    @MainActor static func main() async throws {
        let withToken = AppUsage(bundleID: "com.example.app", name: "示例", seconds: 120, applicationTokenData: Data([1, 2, 3]))
        let decodedApp = try JSONDecoder().decode(AppUsage.self, from: JSONEncoder().encode(withToken))
        precondition(decodedApp == withToken)
        precondition(CSV.header.count == 13 && !CSV.header.contains { $0.hasSuffix("_name") })
        let special = [["日期", "逗号,引号\"换行\n下一行", ""], ["2026-01-01", "普通", "3"]]
        let roundTrip = try CSV.parse(CSV.encode(special)); precondition(roundTrip == special)
        func row(_ day: String, _ value: String) -> [String] { [day, "Asia/Shanghai", value] + Array(repeating: "", count: 10) }
        let old = CSV.encode([CSV.header, row("2026-01-01", "1"), row("2026-01-03", "3")])
        let merged = try CSV.merge(remote: old, local: [row("2026-01-01", "10"), row("2026-01-02", "2")], year: "2026")
        let rows = try CSV.parse(merged)
        precondition(rows.count == 4 && rows[1][2] == "1" && rows[3][0] == "2026-01-03")
        let repeated = try CSV.merge(remote: merged, local: [row("2026-01-01", "10")], year: "2026"); precondition(repeated == merged)
        for invalid in ["bad,header\n", CSV.encode([CSV.header, row("2025-01-01", "1")]), CSV.encode([CSV.header, row("2026-01-01", "1"), row("2026-01-01", "2")]), "\"unclosed"] {
            do { _ = try CSV.merge(remote: invalid, local: [], year: "2026"); fatalError("Accepted invalid CSV") }
            catch is HakoError { }
        }
        let recoveredRow = try DailyUsage.fromCSV(row("2026-01-02", "12.5"), year: "2026")
        precondition(recoveredRow.totalSeconds == 12.5 && recoveredRow.apps.isEmpty)
        var missingAppSeconds = row("2026-01-01", "120")
        missingAppSeconds[3] = "com.example.app"
        var duplicateApps = row("2026-01-01", "120")
        duplicateApps[3] = "com.example.app"; duplicateApps[4] = "1"
        duplicateApps[5] = "com.example.app"; duplicateApps[6] = "2"
        var invalidZone = row("2026-01-01", "120"); invalidZone[1] = "invalid/timezone"
        for invalid in [
            ["2026-01-01"], row("2025-01-01", "1"), row("2026-02-30", "1"), row("2026-1-01", "1"),
            row("2026-01-01", "NaN"), row("2026-01-01", "inf"), row("2026-01-01", "-1"),
            row("2026-01-01", "1e100"), missingAppSeconds, duplicateApps, invalidZone
        ] {
            do { _ = try DailyUsage.fromCSV(invalid, year: "2026"); fatalError("Accepted invalid usage row") }
            catch is HakoError { }
        }
        let iso = ISO8601DateFormatter()
        let newYear = UsageDay(now: iso.date(from: "2026-01-01T01:00:00Z")!, timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        precondition(newYear.key == "2025-12-31")
        let dst = UsageDay(now: iso.date(from: "2026-03-09T12:00:00Z")!, timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        precondition(dst.key == "2026-03-08" && dst.interval.duration == 23 * 3600)
        let yearWeek = UsageDay.recentWeek(now: iso.date(from: "2026-01-04T01:00:00Z")!, timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        precondition(yearWeek.map(\.key) == ["2025-12-28", "2025-12-29", "2025-12-30", "2025-12-31", "2026-01-01", "2026-01-02", "2026-01-03"])
        let dstWeek = UsageDay.recentWeek(now: iso.date(from: "2026-03-09T12:00:00Z")!, timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        precondition(dstWeek.reduce(0) { $0 + $1.interval.duration } == 167 * 3600)
        let container = try ModelContainer(for: DailyUsage.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let record = try DailyUsage(day: "2026-10-14", timeZone: "Asia/Shanghai", totalSeconds: 3600, apps: [AppUsage(bundleID: "test", name: "测试", seconds: 100)])
        context.insert(record); try context.save()
        let saved = try context.fetch(FetchDescriptor<DailyUsage>())
        precondition(saved.count == 1 && saved[0].apps[0].name == "测试" && saved[0].syncedAt == nil)
        saved[0].totalSeconds = 7200; try context.save()
        let count = try context.fetchCount(FetchDescriptor<DailyUsage>()); precondition(count == 1)
        let week = UsageDay.recentWeek(now: iso.date(from: "2026-10-15T10:00:00Z")!, timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        precondition(week.count == 7 && week.first!.key == "2026-10-08" && week.last!.key == "2026-10-14")
        var requested: [String] = []
        let partial = try await UsageBackfill.insertMissing(days: week, context: context) { day in
            requested.append(day.key)
            if day.key == "2026-10-08" { throw HakoError(message: "数据暂不可用") }
            return try DailyUsage(day: day.key, timeZone: day.timeZone, totalSeconds: 100, apps: [])
        }
        precondition(partial.inserted == 5 && partial.skipped == 1 && partial.failures.count == 1)
        precondition(!requested.contains("2026-10-14") && saved[0].totalSeconds == 7200)
        requested = []
        let retry = try await UsageBackfill.insertMissing(days: week, context: context) { day in
            requested.append(day.key)
            return try DailyUsage(day: day.key, timeZone: day.timeZone, totalSeconds: 200, apps: [])
        }
        precondition(retry.inserted == 1 && retry.skipped == 6 && requested == ["2026-10-08"])
        let again = try await UsageBackfill.insertMissing(days: week, context: context) { _ in
            fatalError("An existing day must never be fetched again")
        }
        let finalCount = try context.fetchCount(FetchDescriptor<DailyUsage>())
        precondition(again.skipped == 7 && again.inserted == 0 && finalCount == 7)
        do {
            _ = try UsageMerge.save(rows: [row("2026-10-01", "100"), row("2026-10-02", "NaN")], year: "2026", context: context)
            fatalError("Imported partial invalid archive")
        } catch is HakoError { }
        let afterInvalid = try context.fetchCount(FetchDescriptor<DailyUsage>())
        precondition(afterInvalid == 7)
        let imported = try UsageMerge.save(rows: [row("2026-10-01", "12.5")], year: "2026", context: context)
        precondition(imported.inserted == 1 && imported.updated == 0)
        let updated = try UsageMerge.save(rows: [row("2026-10-01", "12.6")], year: "2026", context: context)
        precondition(updated.inserted == 0 && updated.updated == 1)
        let confirmed = try ModelContext(container).fetch(FetchDescriptor<DailyUsage>()).first { $0.day == "2026-10-01" }!
        precondition(confirmed.totalSeconds == 12.6 && confirmed.syncedAt != nil)
        print("PASS: insert-only CSV; archive validation/import/update/atomicity; 7 completed days/year boundary/DST; local backfill")
    }
}
