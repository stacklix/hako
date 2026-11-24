import Foundation

enum DeviceFilesCommand {
    static let list = "query.files.list"
    static let read = "query.files.read"
    static let operation = "query.files.operation"
    static let mutate = "action.files.mutate"
    static let begin = "action.files.write.begin"
    static let chunk = "action.files.write.chunk"
    static let commit = "action.files.write.commit"
    static let supporting: Set<String> = [read, operation, mutate, begin, chunk, commit]
}

enum DeviceFilePath {
    static func fullPath(root: String, path: String) -> String {
        guard !path.isEmpty else { return root }
        return root + (root.hasSuffix("\\") ? "" : "\\") + path.replacingOccurrences(of: "/", with: "\\")
    }
    static func valid(_ path: String) -> Bool {
        path.isEmpty || (path.count <= 2048 && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { validName(String($0)) })
    }
    static func validName(_ name: String) -> Bool {
        let forbidden = CharacterSet(charactersIn: "<>:\"/\\|?*").union(.controlCharacters)
        guard !name.isEmpty, name.utf16.count <= 255, name != ".", name != "..", !name.hasSuffix("."), !name.hasSuffix(" "),
              name.rangeOfCharacter(from: forbidden) == nil else { return false }
        let stem = name.split(separator: ".", omittingEmptySubsequences: false).first!.uppercased()
        if ["CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"].contains(stem) { return false }
        return !(stem.count == 4 && (stem.hasPrefix("COM") || stem.hasPrefix("LPT")) && "123456789¹²³".contains(stem.last!))
    }
    static func parent(_ path: String) -> String { path.split(separator: "/").dropLast().joined(separator: "/") }
    static func child(_ parent: String, _ name: String) -> String { parent.isEmpty ? name : parent + "/" + name }
    static func isDigest(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
}

struct DeviceFileEntry: Decodable, Identifiable {
    let name: String
    let path: String
    let directory: Bool
    let link: Bool
    let hidden: Bool
    let readOnly: Bool
    let size: Int64
    let modifiedAt: Int64
    let revision: String
    var id: String { path }
    var isMarkdown: Bool { ["md", "markdown"].contains((name as NSString).pathExtension.lowercased()) }
    var isValid: Bool { DeviceFilePath.validName(name) && DeviceFilePath.valid(path) && path.split(separator: "/").last.map(String.init) == name && size >= 0 && modifiedAt >= 0 && DeviceFilePath.isDigest(revision) }
}

struct DeviceFilePage: Decodable {
    let root: String
    let path: String
    let entries: [DeviceFileEntry]
    let nextOffset: Int?
    let truncated: Bool
    func valid(expectedPath: String, offset: Int) -> Bool {
        path == expectedPath && !root.isEmpty && entries.count <= 100 && entries.allSatisfy { $0.isValid && DeviceFilePath.parent($0.path) == path }
            && Set(entries.map(\.id)).count == entries.count
            && (nextOffset == nil || (!entries.isEmpty && nextOffset == offset + entries.count && nextOffset! <= 10_000))
    }
}

struct DeviceFileRead: Decodable {
    let size: Int
    let revision: String?
    let encoding: String?
    let editable: Bool
    let reason: String?
    let data: String?
    let nextOffset: Int?
}

struct DeviceFileDocument {
    let revision: String?
    let encoding: String?
    let editable: Bool
    let reason: String?
    let text: String?
    static let limit = 256 * 1024
    static func decode(_ data: Data, encoding: String) -> String? {
        switch encoding {
        case "utf8": return String(data: data, encoding: .utf8)
        case "utf8-bom": return data.starts(with: [0xef, 0xbb, 0xbf]) ? String(data: data.dropFirst(3), encoding: .utf8) : nil
        case "utf16-le": return data.starts(with: [0xff, 0xfe]) ? String(data: data.dropFirst(2), encoding: .utf16LittleEndian) : nil
        case "utf16-be": return data.starts(with: [0xfe, 0xff]) ? String(data: data.dropFirst(2), encoding: .utf16BigEndian) : nil
        default: return nil
        }
    }
    static func encode(_ text: String, encoding: String) -> Data? {
        switch encoding {
        case "utf8": return text.data(using: .utf8)
        case "utf8-bom": return Data([0xef, 0xbb, 0xbf]) + Data(text.utf8)
        case "utf16-le": return text.data(using: .utf16LittleEndian).map { Data([0xff, 0xfe]) + $0 }
        case "utf16-be": return text.data(using: .utf16BigEndian).map { Data([0xfe, 0xff]) + $0 }
        default: return nil
        }
    }
}

struct DeviceFileOperation: Decodable {
    let requestId: String
    let state: String
    let path: String
    let revision: String?
    let error: String?
    var isValid: Bool { UUID(uuidString: requestId) != nil && ["completed", "failed", "unknown"].contains(state) && DeviceFilePath.valid(path) && (revision == nil || DeviceFilePath.isDigest(revision!)) }
}

struct DeviceFileWriteOffset: Decodable { let offset: Int }
