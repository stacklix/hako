import Foundation

enum CSV {
    static let header = ["date", "timezone", "total_seconds"] + (1...5).flatMap { ["app_\($0)_bundle_id", "app_\($0)_seconds"] }
    static func encode(_ rows: [[String]]) -> String {
        rows.map { $0.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }
    static func parse(_ text: String) throws -> [[String]] {
        let chars = Array(text); var i = 0; var rows: [[String]] = []; var row: [String] = []; var field = ""
        var quoted = false; var closed = false
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i+1] == "\"" { field.append("\""); i += 1 }
                    else { quoted = false; closed = true }
                } else { field.append(c) }
            } else if c == "," { row.append(field); field = ""; closed = false }
            else if c == "\n" || c == "\r\n" || c == "\r" {
                row.append(field); rows.append(row); row = []; field = ""; closed = false
            } else if c == "\"" && field.isEmpty && !closed { quoted = true }
            else {
                guard !closed && c != "\"" else { throw HakoError(message: "远端 CSV 格式异常，已停止覆盖。") }
                field.append(c)
            }
            i += 1
        }
        guard !quoted else { throw HakoError(message: "远端 CSV 引号未闭合。") }
        if !row.isEmpty || !field.isEmpty || closed { row.append(field); rows.append(row) }
        return rows
    }
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
