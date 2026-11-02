import Foundation

struct UsageGitHub {
    let repository: any GitHubRepositoryAccess
    struct PushResult { let rows: [[String]]; let inserted: Int }

    func years(directory: String) async throws -> [String] {
        let index = try await repository.listFiles(in: "data/\(directory)")
        return index.entries.compactMap { entry in
            guard entry.kind == "blob", entry.name.range(of: #"^[0-9]{4}\.csv$"#, options: .regularExpression) != nil else { return nil }
            return String(entry.name.prefix(4))
        }.sorted()
    }

    @discardableResult
    func push(directory: String, year: String, rows: [[String]]) async throws -> PushResult {
        guard year.range(of: #"^[0-9]{4}$"#, options: .regularExpression) != nil else { throw HakoError(message: "年度文件名称无效。") }
        _ = try rows.map { try DailyUsage.fromCSV($0, year: year) }
        let path = "data/\(directory)/\(year).csv"
        for attempt in 0..<3 {
            try Task.checkCancellation()
            let snapshot = try await repository.readFile(at: path, revision: nil)
            let remote = snapshot.text
            let csv = try CSV.merge(remote: remote, local: rows, year: year)
            let mergedRows = Array(try CSV.parse(csv).dropFirst())
            _ = try mergedRows.map { try DailyUsage.fromCSV($0, year: year) }
            let existingDates = Set(try remote.map { try CSV.parse($0).dropFirst().map { $0[0] } } ?? [])
            let newDates = Set(rows.map { $0[0] }).subtracting(existingDates).sorted()
            guard let first = newDates.first, let last = newDates.last else { return PushResult(rows: mergedRows, inserted: 0) }
            let label = first == last ? first : "\(first) ~ \(last)"
            let result = try await repository.commit(files: [path: csv], expectedHead: snapshot.head,
                message: GitHubCommitMessage(headline: "Update \(directory): \(label)", body: "Add missing dates: " + newDates.joined(separator: ", ")))
            if result == .staleHead {
                if attempt < 2 { continue }
                throw HakoError(message: "GitHub 分支持续变化，请稍后重试合并。")
            }
            return PushResult(rows: mergedRows, inserted: newDates.count)
        }
        throw HakoError(message: "GitHub 分支持续变化，请稍后重试合并。")
    }
}
