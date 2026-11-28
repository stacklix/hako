import Foundation

enum WorkshopFileScope: String, CaseIterable { case all = "所有文件", modified = "已修改" }

/// Resolve message links on the execution computer, never against the phone's filesystem.
struct WorkshopProjectLink {
    let path: String
    var file: WorkshopProjectFile {
        .init(name: (path as NSString).lastPathComponent, path: path, directory: false, link: false, size: 0, status: nil)
    }

    init?(url: URL, projectPath: String) {
        guard !projectPath.isEmpty, url.query == nil, url.user == nil, url.password == nil else { return nil }
        func normalized(_ value: String) -> String {
            var value = value.replacingOccurrences(of: "\\", with: "/")
            if value.hasPrefix("//?/UNC/") { value = "//" + value.dropFirst(8) }
            else if value.hasPrefix("//?/") { value = String(value.dropFirst(4)) }
            if value.range(of: #"^/[A-Za-z]:/"#, options: .regularExpression) != nil { value.removeFirst() }
            return value
        }
        func components(_ value: String) -> [String]? {
            var result: [String] = []
            for part in value.split(separator: "/") {
                if part == "." { continue }
                if part == ".." {
                    guard !result.isEmpty else { return nil }
                    result.removeLast()
                } else { result.append(String(part)) }
            }
            return result
        }
        let root = normalized(projectPath)
        let windows = root.range(of: #"^[A-Za-z]:/"#, options: .regularExpression) != nil || root.hasPrefix("//")
        let address: String
        if url.isFileURL {
            guard url.host == nil || url.host == "" || url.host?.lowercased() == "localhost" else { return nil }
            address = url.path
        } else {
            let raw = url.relativeString.components(separatedBy: "#")[0]
            let drive = raw.range(of: #"^/?[A-Za-z]:[/\\]"#, options: .regularExpression) != nil
            guard url.scheme == nil || drive else { return nil }
            guard let decoded = raw.removingPercentEncoding else { return nil }
            address = decoded
        }
        let destination = normalized(address).replacingOccurrences(of: #":[1-9][0-9]*(?::[1-9][0-9]*)?$"#, with: "", options: .regularExpression)
        guard !destination.isEmpty, !destination.hasSuffix("/"),
              let rootParts = components(root), !rootParts.isEmpty,
              let targetParts = components(destination) else { return nil }
        let absolute = destination.hasPrefix("/") || destination.range(of: #"^[A-Za-z]:/"#, options: .regularExpression) != nil
        let relative: [String]
        if absolute {
            guard targetParts.count > rootParts.count,
                  zip(rootParts, targetParts).allSatisfy({ windows ? $0.caseInsensitiveCompare($1) == .orderedSame : $0 == $1 }) else { return nil }
            relative = Array(targetParts.dropFirst(rootParts.count))
        } else { relative = targetParts }
        guard !relative.isEmpty, !relative.contains(where: { $0.contains(":") || $0.lowercased() == ".git" || $0.contains("\0") }) else { return nil }
        path = relative.joined(separator: "/")
    }
}

struct WorkshopProjectFile: Decodable, Identifiable, Equatable {
    let name: String
    let path: String
    let directory: Bool
    let link: Bool
    let size: Int64
    let status: String?
    var id: String { path }
    var deleted: Bool { status?.contains("D") == true }
    var statusLabel: String? {
        guard let status else { return nil }
        if status.contains("?") { return "新增" }
        if status.contains("D") { return "删除" }
        if status.contains("R") { return "重命名" }
        if status.contains("A") { return "新增" }
        return "修改"
    }
}

struct WorkshopFilePage: Decodable {
    let entries: [WorkshopProjectFile]
    let nextOffset: Int?
    let truncated: Bool
}

struct WorkshopFileRead: Decodable {
    let size: Int
    let editable: Bool
    let reason: String?
    let revision: String?
    let encoding: String?
    let data: String?
    let nextOffset: Int?
}

enum WorkshopProjectImage {
    static let limit = 8 * 1024 * 1024
    static func supports(_ path: String) -> Bool {
        ["png", "jpg", "jpeg", "gif", "webp"].contains((path as NSString).pathExtension.lowercased())
    }
}

enum WorkshopFileText {
    static let limit = 256 * 1024
    static func decode(_ data: Data, encoding: String) -> String? {
        switch encoding {
        case "utf8": return String(data: data, encoding: .utf8)
        case "utf8-bom": return String(data: data.dropFirst(3), encoding: .utf8)
        case "utf16-le": return String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        case "utf16-be": return String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        default: return nil
        }
    }
    static func encode(_ text: String, encoding: String) -> Data? {
        switch encoding {
        case "utf8": return text.data(using: .utf8)
        case "utf8-bom": return text.data(using: .utf8).map { Data([0xef, 0xbb, 0xbf]) + $0 }
        case "utf16-le": return text.data(using: .utf16LittleEndian).map { Data([0xff, 0xfe]) + $0 }
        case "utf16-be": return text.data(using: .utf16BigEndian).map { Data([0xfe, 0xff]) + $0 }
        default: return nil
        }
    }
}
