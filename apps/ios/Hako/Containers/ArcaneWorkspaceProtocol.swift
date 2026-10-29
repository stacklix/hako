import Foundation

struct ArcaneComposeReference: Decodable {
    let projectName: String
    let workingDir: String?
}

struct ArcaneProjectSummary: Decodable, Identifiable {
    let id: String
    let name: String
    let path: String?

    static func resolve(_ projects: [Self], name: String, workingDir: String?) throws -> Self {
        let matches = projects.filter { $0.name == name }
        if let workingDir, !workingDir.isEmpty {
            let exact = matches.filter { $0.path?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == workingDir.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
            if exact.count == 1 { return exact[0] }
        }
        guard matches.count == 1 else {
            throw ArcaneFailure(message: matches.isEmpty ? "Arcane 尚未收录此 Compose 项目，无法访问项目文件。请先在 Arcane 中确认项目目录。" : "发现多个同名 Compose 项目，无法确定文件目录。请先在 Arcane 中核对项目名称和路径。")
        }
        return matches[0]
    }
}

enum ArcaneProjectFileKind: String, Identifiable {
    case compose, env, override, workspace
    var id: String { rawValue }
}

struct ArcaneProjectDocument: Decodable {
    let id: String
    let name: String
    let path: String?
    let composeContent: String?
    let composeFileName: String?
    let envContent: String?
    let overrideContent: String?
    let overrideFileName: String?
    let gitOpsManagedBy: String?
    let isArchived: Bool?

    var configurationFiles: [ArcaneProjectFile] {
        var files = [ArcaneProjectFile(relativePath: composeFileName ?? "compose.yaml", kind: .compose),
                     ArcaneProjectFile(relativePath: ".env", kind: .env)]
        if let name = overrideFileName, !name.isEmpty {
            files.append(ArcaneProjectFile(relativePath: name, kind: .override))
        }
        return files
    }
    func content(_ kind: ArcaneProjectFileKind) -> String {
        switch kind {
        case .compose: return composeContent ?? ""
        case .env: return envContent ?? ""
        case .override: return overrideContent ?? ""
        case .workspace: return ""
        }
    }
    func editable(_ kind: ArcaneProjectFileKind) -> Bool {
        isArchived != true && (kind == .env || gitOpsManagedBy?.isEmpty != false)
    }
}

struct ArcaneProjectPatch: Encodable {
    var composeContent: String?
    var envContent: String?
    var overrideContent: String?

    init(kind: ArcaneProjectFileKind, content: String) throws {
        switch kind {
        case .compose: composeContent = content
        case .env: envContent = content
        case .override: overrideContent = content
        case .workspace: throw ArcaneFailure(message: "此文件需要通过项目文件接口保存。")
        }
    }
}

struct ArcaneProjectFile: Identifiable {
    let relativePath: String
    let kind: ArcaneProjectFileKind
    var entry: ArcaneWorkspaceEntry?
    var id: String { relativePath }
    var name: String { relativePath.split(separator: "/").last.map(String.init) ?? relativePath }
    var isDirectory: Bool { entry?.isDirectory == true }
}

// Own the complete presentation input independently of directory reloads.
struct ArcaneFileEditorSession: Identifiable {
    let id = UUID()
    let environment: String
    let project: ArcaneProjectDocument
    let initialFile: ArcaneProjectFile
}

struct ArcaneWorkspace: Decodable {
    let files: [ArcaneWorkspaceEntry]
    let fileTreeRevision: String
    let fileTreeTruncated: Bool
}

struct ArcaneWorkspaceEntry: Decodable, Identifiable {
    let name: String
    let relativePath: String
    let size: Int64
    let isDirectory: Bool
    let isSymlink: Bool
    let editable: Bool
    let readOnlyReason: String?
    var id: String { relativePath }
}

struct ArcaneWorkspaceContent: Decodable {
    let relativePath: String
    let content: String?
    let mimeType: String
    let size: Int64
    let editable: Bool
    let readOnlyReason: String?
    var viewable: Bool {
        !["binary", "too_large", "symlink", "special"].contains(readOnlyReason ?? "") && content?.contains("\0") != true
    }
    var reasonText: String? { ArcaneWorkspacePath.reason(readOnlyReason) }
}

enum ArcaneWorkspacePath {
    static func validate(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw ArcaneFailure(message: "项目文件路径无效。")
        }
    }
    static func parent(_ path: String) -> String {
        path.split(separator: "/").dropLast().joined(separator: "/")
    }
    static func reason(_ value: String?) -> String? {
        switch value {
        case "binary": return "二进制文件，不支持查看和编辑内容。"
        case "too_large": return "文件超过 Arcane 允许的编辑大小。"
        case "symlink": return "符号链接不支持查看和编辑内容。"
        case "special": return "此文件类型不支持查看和编辑内容。"
        case "gitops_managed": return "由 Git 同步管理，请在源仓库修改此文件。"
        case .none, .some(""): return nil
        case .some: return "此文件由服务端设为只读。"
        }
    }
}

struct ArcaneWorkspaceManifest: Encodable {
    let fileTreeRevision: String
    let fileChanges: [Change]
    struct Change: Encodable {
        let operation = "update_file"
        let relativePath: String
        let uploadIndex = 0
        let baselineIndex = 1
    }
}
