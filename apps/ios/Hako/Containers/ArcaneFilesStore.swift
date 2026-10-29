import Foundation
import Combine

@MainActor final class ArcaneFilesData: ObservableObject {
    @Published private(set) var project: ArcaneProjectDocument?
    @Published private(set) var workspace: ArcaneWorkspace?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private var ticket: UUID?
    private var context = ""

    var files: [ArcaneProjectFile] {
        guard let project, let workspace else { return [] }
        var entries = Dictionary(uniqueKeysWithValues: workspace.files.map {
            ($0.relativePath, ArcaneProjectFile(relativePath: $0.relativePath, kind: .workspace, entry: $0))
        })
        for file in project.configurationFiles { entries[file.id] = file }
        for file in Array(entries.values) {
            var parent = ArcaneWorkspacePath.parent(file.relativePath)
            while !parent.isEmpty {
                if entries[parent] == nil {
                    let entry = ArcaneWorkspaceEntry(name: parent.split(separator: "/").last.map(String.init) ?? parent,
                        relativePath: parent, size: 0, isDirectory: true, isSymlink: false, editable: false, readOnlyReason: nil)
                    entries[parent] = ArcaneProjectFile(relativePath: parent, kind: .workspace, entry: entry)
                }
                parent = ArcaneWorkspacePath.parent(parent)
            }
        }
        return Array(entries.values)
    }

    func fail(_ error: Error) { ticket = nil; self.error = error.localizedDescription; loading = false }

    func load(client: ArcaneClient, environment: String, name: String, workingDir: String?) async {
        let current = UUID(); ticket = current; loading = true; error = nil
        let context = "\(client.connection.id):\(environment):\(name):\(workingDir ?? "")"
        if self.context != context { self.context = context; project = nil; workspace = nil }
        defer { if ticket == current { loading = false } }
        do {
            let projects = try await client.projects(environment)
            let match = try ArcaneProjectSummary.resolve(projects, name: name, workingDir: workingDir)
            async let document = client.projectDocument(environment, project: match.id)
            async let tree = client.workspace(environment, project: match.id)
            let (value, workspace) = try await (document, tree)
            for file in value.configurationFiles { try ArcaneWorkspacePath.validate(file.relativePath) }
            try Task.checkCancellation()
            guard ticket == current else { return }
            project = value; self.workspace = workspace
        } catch is CancellationError { }
        catch { if ticket == current { self.error = error.localizedDescription } }
    }
}

@MainActor final class ArcaneFileEditorData: ObservableObject {
    @Published var draft = "" {
        didSet { if draft != baseline { notice = nil } }
    }
    @Published private(set) var loading = true
    @Published private(set) var saving = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published private(set) var viewable = false
    @Published private(set) var editable = false
    @Published private(set) var readOnlyReason: String?
    @Published private(set) var size: Int64 = 0
    @Published private(set) var mimeType = ""
    @Published private(set) var uncertain = false
    private var baseline = ""
    private var revision = ""
    private var connectionID: String?
    private var loadedEnvironment: String?
    private var loadedProject: String?
    private var loadedFile: String?
    private var loadedKind: ArcaneProjectFileKind?
    private var readTicket: UUID?
    var dirty: Bool { draft != baseline }

    func fail(_ error: Error) { readTicket = nil; self.error = error.localizedDescription; loading = false }

    func load(client: ArcaneClient, environment: String, project: ArcaneProjectDocument, file: ArcaneProjectFile) async {
        let ticket = UUID(); readTicket = ticket
        loading = true; error = nil; notice = nil
        defer { if readTicket == ticket { loading = false } }
        do {
            if let entry = file.entry, entry.isSymlink || ["binary", "too_large", "special"].contains(entry.readOnlyReason ?? "") {
                viewable = false; editable = false; size = entry.size
                readOnlyReason = ArcaneWorkspacePath.reason(entry.isSymlink ? "symlink" : entry.readOnlyReason)
                return
            }
            if file.kind == .workspace {
                async let tree = client.workspace(environment, project: project.id)
                async let contents = client.workspaceFile(environment, project: project.id, path: file.relativePath)
                let (workspace, value) = try await (tree, contents)
                try Task.checkCancellation()
                guard readTicket == ticket else { return }
                revision = workspace.fileTreeRevision
                draft = value.content ?? ""
                viewable = value.viewable
                editable = value.editable && value.viewable && project.isArchived != true
                readOnlyReason = value.reasonText ?? (project.isArchived == true ? "项目已归档，文件只读。" : nil)
                size = value.size; mimeType = value.mimeType
            } else {
                let value = try await client.projectDocument(environment, project: project.id)
                try Task.checkCancellation()
                guard readTicket == ticket else { return }
                guard value.configurationFiles.contains(where: { $0.kind == file.kind && $0.id == file.id }) else {
                    throw ArcaneFailure(message: "项目配置文件的位置已改变，请关闭编辑器并刷新目录。")
                }
                draft = value.content(file.kind)
                viewable = true; editable = value.editable(file.kind)
                readOnlyReason = editable ? nil : "此配置由 Git 同步管理或项目已归档，文件只读。"
                size = Int64(draft.utf8.count); mimeType = "text/plain"
            }
            baseline = draft; connectionID = client.connection.id; uncertain = false
            loadedEnvironment = environment; loadedProject = project.id; loadedFile = file.id; loadedKind = file.kind
        } catch is CancellationError { }
        catch { if readTicket == ticket { self.error = error.localizedDescription } }
    }

    func save(store: ArcaneStore, environment: String, project: ArcaneProjectDocument, file: ArcaneProjectFile) async {
        guard !loading, !saving, editable, dirty, !uncertain else { return }
        saving = true; error = nil; notice = nil
        defer { saving = false }
        do {
            let client = try store.client()
            guard client.connection.id == connectionID, environment == loadedEnvironment,
                  project.id == loadedProject, file.id == loadedFile, file.kind == loadedKind else {
                throw ArcaneFailure(message: "Arcane 连接或项目文件已改变，请重新打开项目文件。")
            }
            let proposed = draft
            var committed = proposed
            try await store.withFileSave {
                if file.kind == .workspace {
                    let value = try await client.saveWorkspaceFile(environment, project: project.id, path: file.relativePath,
                        revision: revision, baseline: baseline, content: proposed)
                    revision = value.fileTreeRevision
                } else {
                    let value = try await client.saveProjectFile(environment, project: project.id, kind: file.kind,
                        baseline: baseline, content: proposed)
                    committed = value.content(file.kind)
                }
            }
            draft = committed; baseline = committed; size = Int64(committed.utf8.count)
            notice = "文件已保存，未执行部署或重启。"
        } catch {
            uncertain = (error as? ArcaneFailure)?.outcomeUnknown == true
            if uncertain {
                self.error = "保存结果未确认，当前草稿已保留。请重新读取服务器文件核对，勿直接重复保存。"
            } else if (error as? ArcaneFailure)?.status == 409 {
                self.error = "文件或目录已被其他操作修改，当前草稿已保留。请重新读取服务器内容后再编辑。"
            } else if [400, 422].contains((error as? ArcaneFailure)?.status ?? 0) {
                self.error = "文件内容未通过 Arcane 校验，请检查 Compose YAML、变量引用或文件格式。当前草稿已保留。"
            } else { self.error = error.localizedDescription }
        }
    }
}
