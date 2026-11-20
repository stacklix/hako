import Foundation

enum WorkshopFileScope: String, CaseIterable { case all = "所有文件", modified = "已修改" }

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
