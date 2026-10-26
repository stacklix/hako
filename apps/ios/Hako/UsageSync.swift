import Foundation
import SwiftData

@MainActor enum UsageSync {
    struct Result {
        var inserted = 0
        var updated = 0
        var days = 0
    }

    static func merge(context: ModelContext, client: GitHubClient, directory: String) async throws -> Result {
        let local = try context.fetch(FetchDescriptor<DailyUsage>())
        let grouped = Dictionary(grouping: local) { String($0.day.prefix(4)) }
        let remoteYears = try await client.years(directory: directory)
        let years = Set(grouped.keys).union(remoteYears).sorted()
        var result = Result()
        for year in years {
            try Task.checkCancellation()
            let rows = try await client.push(directory: directory, year: year, rows: (grouped[year] ?? []).map(\.csvRow))
            let saved = try UsageMerge.save(rows: rows, year: year, context: context)
            result.inserted += saved.inserted
            result.updated += saved.updated
            result.days += rows.count
        }
        return result
    }
}
