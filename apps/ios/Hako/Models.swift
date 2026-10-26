import Foundation
import SwiftData

struct AppUsage: Codable, Hashable {
    let bundleID: String
    let name: String
    var seconds: Double
    // The system may omit the application token.
    var applicationTokenData: Data? = nil
}

@Model final class DailyUsage {
    @Attribute(.unique) var day: String
    var timeZone: String
    var totalSeconds: Double
    var appsData: Data
    var capturedAt: Date
    var syncedAt: Date?
    init(day: String, timeZone: String, totalSeconds: Double, apps: [AppUsage]) throws {
        self.day = day; self.timeZone = timeZone; self.totalSeconds = totalSeconds.rounded()
        // Round once after collection has aggregated usage, before persisting the record.
        let roundedApps = apps.map { app in
            var value = app
            value.seconds = value.seconds.rounded()
            return value
        }
        self.appsData = try JSONEncoder().encode(roundedApps); self.capturedAt = .now
    }
    var apps: [AppUsage] { (try? JSONDecoder().decode([AppUsage].self, from: appsData)) ?? [] }
    var csvRow: [String] {
        var row = [day, timeZone, String(Int(totalSeconds.rounded()))]
        let values = apps
        for index in 0..<5 {
            if index < values.count {
                row += [values[index].bundleID, String(Int(values[index].seconds.rounded()))]
            } else { row += ["", ""] }
        }
        return row
    }

    static func fromCSV(_ row: [String], year: String) throws -> DailyUsage {
        let invalid = HakoError(message: "年度 \(year) 的 CSV 含无效日期、时区或时长，已停止合并。")
        guard row.count == 13,
              row[0].range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil,
              row[0].hasPrefix(year + "-"), TimeZone(identifier: row[1]) != nil,
              let total = Double(row[2]), total.isFinite, total >= 0, total < Double(Int.max) else { throw invalid }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: row[0]), formatter.string(from: date) == row[0] else { throw invalid }
        var apps: [AppUsage] = []
        var bundleIDs: Set<String> = []
        for index in stride(from: 3, to: row.count, by: 2) {
            let bundleID = row[index], value = row[index + 1]
            if bundleID.isEmpty && value.isEmpty { continue }
            guard !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let seconds = Double(value), seconds.isFinite, seconds >= 0, seconds < Double(Int.max),
                  bundleIDs.insert(bundleID).inserted else { throw invalid }
            apps.append(AppUsage(bundleID: bundleID, name: bundleID, seconds: seconds))
        }
        return try DailyUsage(day: row[0], timeZone: row[1], totalSeconds: total, apps: apps)
    }
}

@MainActor enum UsageMerge {
    struct Result {
        var inserted = 0
        var updated = 0
    }

    static func save(rows: [[String]], year: String, context: ModelContext) throws -> Result {
        // Decode the entire file first so a malformed row cannot leave a partial import.
        let incoming = try rows.map { try DailyUsage.fromCSV($0, year: year) }
        guard Set(incoming.map(\.day)).count == incoming.count else {
            throw HakoError(message: "年度 \(year) 的 CSV 日期重复，已停止合并。")
        }
        let existing = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<DailyUsage>()).map { ($0.day, $0) })
        var result = Result()
        do {
            for record in incoming {
                if let local = existing[record.day] {
                    // Compare at the exported whole-second precision. Local subsecond values,
                    // app names/tokens and sync timestamps do not represent archive changes.
                    let changed = local.csvRow != record.csvRow
                    if changed {
                        // CSV has no display names or tokens; keep matching local app metadata.
                        let apps = record.apps.map { app in
                            let metadata = local.apps.first { $0.bundleID == app.bundleID }
                            return AppUsage(bundleID: app.bundleID, name: metadata?.name ?? app.name,
                                            seconds: app.seconds, applicationTokenData: metadata?.applicationTokenData)
                        }
                        local.appsData = try JSONEncoder().encode(apps)
                        local.timeZone = record.timeZone
                        local.totalSeconds = record.totalSeconds
                        result.updated += 1
                    }
                    if changed || local.syncedAt == nil { local.syncedAt = .now }
                } else {
                    record.syncedAt = .now
                    context.insert(record)
                    result.inserted += 1
                }
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        return result
    }
}

struct HakoError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor enum Database {
    static let shared: Result<ModelContainer, Error> = Result { try ModelContainer(for: DailyUsage.self) }
    static func context() throws -> ModelContext { ModelContext(try shared.get()) }
}

struct UsageDay {
    let interval: DateInterval
    let key: String
    let timeZone: String
    init(now: Date = .now, timeZone: TimeZone = .current, daysAgo: Int = 1) {
        precondition(daysAgo >= 1)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -daysAgo, to: today)!
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        interval = DateInterval(start: start, end: end)
        let formatter = DateFormatter(); formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        key = formatter.string(from: start); self.timeZone = timeZone.identifier
    }
    static func recentWeek(now: Date = .now, timeZone: TimeZone = .current) -> [UsageDay] {
        (1...7).reversed().map { UsageDay(now: now, timeZone: timeZone, daysAgo: $0) }
    }
}

@MainActor enum UsageBackfill {
    struct Result {
        var inserted = 0
        var skipped = 0
        var failures: [String] = []
    }
    static func insertMissing(days: [UsageDay], context: ModelContext,
                              collect: (UsageDay) async throws -> DailyUsage) async throws -> Result {
        var result = Result()
        var existing = Set(try context.fetch(FetchDescriptor<DailyUsage>()).map(\.day))
        for day in days {
            try Task.checkCancellation()
            guard !existing.contains(day.key) else { result.skipped += 1; continue }
            let record: DailyUsage
            do { record = try await collect(day) }
            catch is CancellationError { throw CancellationError() }
            catch {
                result.failures.append("\(day.key)：\(error.localizedDescription)")
                continue
            }
            context.insert(record)
            try context.save()
            existing.insert(day.key)
            result.inserted += 1
        }
        return result
    }
}
