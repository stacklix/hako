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
        self.day = day; self.timeZone = timeZone; self.totalSeconds = totalSeconds
        self.appsData = try JSONEncoder().encode(apps); self.capturedAt = .now
    }
    var apps: [AppUsage] { (try? JSONDecoder().decode([AppUsage].self, from: appsData)) ?? [] }
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
