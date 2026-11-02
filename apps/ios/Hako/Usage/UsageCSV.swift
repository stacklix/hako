import Foundation

extension CSV {
    static let header = ["date", "timezone", "total_seconds"] + (1...5).flatMap { ["app_\($0)_bundle_id", "app_\($0)_seconds"] }
    static func merge(remote: String?, local: [[String]], year: String) throws -> String {
        var byDay: [String: [String]] = [:]
        if let remote {
            let rows = try parse(remote)
            guard rows.first == header else { throw HakoError(message: "远端 CSV 表头不兼容，已停止覆盖。") }
            for row in rows.dropFirst() {
                guard row.count == header.count, row[0].hasPrefix(year + "-"), byDay[row[0]] == nil else {
                    throw HakoError(message: "远端 CSV 行无效或日期重复，已停止覆盖。")
                }
                byDay[row[0]] = row
            }
        }
        for row in local where byDay[row[0]] == nil { byDay[row[0]] = row }
        return encode([header] + byDay.keys.sorted().compactMap { byDay[$0] })
    }
}
