import Foundation

struct HakoBackupError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// The child contract contains no storage vendor, account or credential details.
@MainActor protocol HakoDataBackupAccess {
    func backup(data: Data, applicationID: String, file: HakoBackupFile, mimeType: String, at date: Date) async throws -> HakoBackupReport
    func latestReport(applicationID: String) -> HakoBackupReport?
}

struct HakoBackupFile: Codable, Equatable {
    var subdirectory: String
    var fileName: String

    func resolved(at date: Date = Date()) throws -> (directories: [String], fileName: String) {
        let directories = try HakoBackupPath.components(subdirectory)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        formatter.dateFormat = "yyyy-MM-dd"
        var name = fileName.replacingOccurrences(of: "{date}", with: formatter.string(from: date))
        formatter.dateFormat = "HHmmssSSS"
        name = name.replacingOccurrences(of: "{time}", with: formatter.string(from: date))
        guard !name.contains("{"), !name.contains("}"), try HakoBackupPath.components(name) == [name] else {
            throw HakoBackupError(message: "文件名不能包含路径，只支持 {date} 和 {time} 占位符。")
        }
        return (directories, name)
    }
}

enum HakoBackupPath {
    static func components(_ path: String) throws -> [String] {
        if path.isEmpty { return [] }
        let parts = path.components(separatedBy: "/")
        guard parts.count <= 16, parts.allSatisfy({ part in
            !part.isEmpty && part != "." && part != ".." && part.utf8.count <= 240 &&
                part == part.trimmingCharacters(in: .whitespacesAndNewlines) &&
                !part.contains("\\") && !part.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }) else { throw HakoBackupError(message: "目录或文件名无效：使用 / 分隔目录，不能含空段、首尾空格、反斜线或 ..。") }
        return parts
    }
}

struct HakoBackupReport: Codable {
    struct Destination: Codable, Identifiable {
        let id: UUID
        let name: String
        let path: String?
        let failure: String?
        var succeeded: Bool { failure == nil }
    }
    let completedAt: Date
    let byteCount: Int
    let expectedCount: Int
    let destinations: [Destination]
    var succeeded: Bool { destinations.count == expectedCount && expectedCount > 0 && destinations.allSatisfy(\.succeeded) }
    var message: String {
        var lines = destinations.map { result in
            result.failure.map { "\(result.name)：失败，\($0)" } ?? "\(result.name)：已备份并校验，\(result.path ?? "")"
        }
        if destinations.count < expectedCount { lines.append("还有 \(expectedCount - destinations.count) 个目的地尚未完成。") }
        return lines.joined(separator: "\n")
    }
}
