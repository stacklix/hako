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
        var operation = "update_file"
        let relativePath: String
        var newName: String? = nil
        var uploadIndex: Int? = 0
        var baselineIndex: Int? = 1
    }
}

enum ArcaneWorkspaceMutation {
    case createFile(parent: String), createFolder(parent: String), rename(ArcaneProjectFile)

    var title: String {
        switch self {
        case .createFile: return "新建文件"
        case .createFolder: return "新建文件夹"
        case .rename(let file): return file.isDirectory ? "重命名文件夹" : "重命名文件"
        }
    }
    var initialName: String { if case .rename(let file) = self { return file.name }; return "" }
    var nameHint: String {
        switch self {
        case .createFile: return "例如 config.yaml"
        case .createFolder: return "例如 config"
        case .rename: return "输入新名称"
        }
    }
    var parent: String {
        switch self {
        case .createFile(let parent), .createFolder(let parent): return parent
        case .rename(let file): return ArcaneWorkspacePath.parent(file.relativePath)
        }
    }
    var isRename: Bool { if case .rename = self { return true }; return false }

    func restriction(project: ArcaneProjectDocument, workspace: ArcaneWorkspace) -> String? {
        if project.isArchived == true { return "项目已归档，不能修改文件或目录。" }
        if case .rename(let file) = self {
            if file.kind != .workspace { return "Compose、.env 等核心配置由 Arcane 保护，不支持重命名。" }
            guard let current = workspace.files.first(where: { $0.id == file.id }), current.isDirectory == file.isDirectory else {
                return "原文件或目录已改变，请重新读取目录。"
            }
            if current.isSymlink { return "符号链接不支持重命名。" }
            if workspace.files.contains(where: { ($0.id == file.id || $0.id.hasPrefix(file.id + "/")) && $0.readOnlyReason == "gitops_managed" }) {
                return "此文件或目录包含 Git 同步管理的内容，请在源仓库重命名。"
            }
            if !current.editable && !["binary", "too_large"].contains(current.readOnlyReason ?? "") {
                return "此文件或目录由服务端设为只读，不支持重命名。"
            }
        }
        return nil
    }

    func plan(name: String, project: ArcaneProjectDocument, workspace: ArcaneWorkspace) throws -> ArcaneWorkspaceMutationPlan {
        if let reason = restriction(project: project, workspace: workspace) { throw ArcaneFailure(message: reason) }
        if !parent.isEmpty {
            try ArcaneWorkspacePath.validate(parent)
            guard let directory = workspace.files.first(where: { $0.id == parent }), directory.isDirectory, !directory.isSymlink else {
                throw ArcaneFailure(message: "当前目录已改变或不支持写入，请重新读取目录。")
            }
            if directory.readOnlyReason == "gitops_managed" { throw ArcaneFailure(message: "此目录由 Git 同步管理，不能修改。") }
        }
        let name = try Self.validateName(name)
        let target = parent.isEmpty ? name : parent + "/" + name
        try ArcaneWorkspacePath.validate(target)
        if workspace.files.contains(where: { $0.id == target }) || project.configurationFiles.contains(where: { $0.id == target }) {
            if case .rename(let file) = self, file.id == target { throw ArcaneFailure(message: "新名称与当前名称相同。") }
            throw ArcaneFailure(message: "当前目录已有同名文件或文件夹，请换一个名称。", status: 409)
        }
        if parent.isEmpty && Self.protectedNames(project: project).contains(name) {
            throw ArcaneFailure(message: "此名称属于 Arcane 保护的项目配置，不能通过文件管理创建或重命名。")
        }
        switch self {
        case .createFile:
            return ArcaneWorkspaceMutationPlan(change: .init(operation: "create_file", relativePath: target, uploadIndex: 0, baselineIndex: nil), uploads: [Data()], target: target)
        case .createFolder:
            return ArcaneWorkspaceMutationPlan(change: .init(operation: "create_folder", relativePath: target, uploadIndex: nil, baselineIndex: nil), uploads: [], target: target)
        case .rename(let file):
            try ArcaneWorkspacePath.validate(file.id)
            return ArcaneWorkspaceMutationPlan(change: .init(operation: "rename", relativePath: file.id, newName: name, uploadIndex: nil, baselineIndex: nil), uploads: [], target: target)
        }
    }

    static func validateName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"), name.utf8.count <= 255,
              !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw ArcaneFailure(message: "请输入有效名称，不能包含路径分隔符、控制字符或超过 255 字节。")
        }
        return name
    }

    private static func protectedNames(project: ArcaneProjectDocument) -> Set<String> {
        Set(["compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml", ".env", ".env.git", "project.env",
             "compose.override.yaml", "compose.override.yml", "docker-compose.override.yaml", "docker-compose.override.yml"]
            + project.configurationFiles.map(\.relativePath))
    }
}

struct ArcaneWorkspaceMutationPlan {
    let change: ArcaneWorkspaceManifest.Change
    let uploads: [Data]
    let target: String
}

struct ArcaneFileMutationSession: Identifiable {
    let id = UUID()
    let connectionID: String
    let environment: String
    let project: ArcaneProjectDocument
    let workspace: ArcaneWorkspace
    let mutation: ArcaneWorkspaceMutation
}
