import SwiftUI
import UIKit

struct ArcaneProjectFilesSection: View {
    @ObservedObject var store: ArcaneStore
    let environment: String
    let projectName: String?
    let workingDir: String?
    let refreshID: UUID
    var scrollToFile: (String) -> Void = { _ in }
    let openEditor: (ArcaneFileEditorSession) -> Void
    @StateObject private var data = ArcaneFilesData()
    @State private var folder = ""
    @State private var reloadID = UUID()
    @State private var bookmarks: [String: String] = [:]

    private var context: String {
        "\(store.connection?.id ?? "")-\(environment)-\(projectName ?? "")-\(workingDir ?? "")-\(refreshID)-\(reloadID)"
    }
    private var entries: [ArcaneProjectFile] {
        data.files.filter { ArcaneWorkspacePath.parent($0.relativePath) == folder }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }
    private var rootDirectoryName: String {
        let candidates = [data.project?.path, workingDir]
        guard let path = candidates.compactMap({ $0 }).first(where: { !$0.isEmpty }) else {
            return data.project?.name ?? projectName ?? "文件"
        }
        return path.split(separator: "/").last.map(String.init) ?? "/"
    }

    var body: some View {
        Section {
            if projectName?.isEmpty != false {
                ContentUnavailableView("没有 Compose 项目目录", systemImage: "folder",
                    description: Text("此容器未关联 Compose 项目。项目文件需要先由 Arcane 收录和管理。"))
            }
            if data.loading { ProgressView("正在读取项目文件…").arcaneRowSeparators() }
            if let error = data.error {
                Text(error).font(.footnote).foregroundStyle(.orange).arcaneRowSeparators()
                Button("重新读取目录") { reloadID = UUID() }.arcaneRowSeparators()
            }
            if data.workspace != nil {
                if data.workspace?.fileTreeTruncated == true {
                    Text("目录超过 Arcane 的文件数量或深度限制，当前列表未完整返回。")
                        .font(.footnote).foregroundStyle(.orange).arcaneRowSeparators()
                }
                if entries.isEmpty { Text("此目录没有文件").foregroundStyle(.secondary).arcaneRowSeparators() }
                ForEach(entries) { file in fileRow(file).id("arcane-file-" + file.id) }
            }
        } header: {
            VStack(alignment: .leading, spacing: 4) {
                Text("文件")
                if projectName?.isEmpty == false {
                    ArcaneFileBreadcrumbs(rootName: rootDirectoryName, folder: folder) { navigate($0) }
                }
            }.textCase(nil).id("arcane-file-directory")
                .task(id: context) { await reload() }
        }
    }

    private func fileRow(_ file: ArcaneProjectFile) -> some View {
        let readOnly = file.entry?.editable == false || (file.kind != .workspace && data.project?.editable(file.kind) == false)
        return Button {
            bookmarks[folder] = file.id
            if file.isDirectory && file.entry?.isSymlink != true { navigate(file.relativePath) }
            else if let project = data.project {
                openEditor(ArcaneFileEditorSession(environment: environment, project: project, initialFile: file))
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: file.isDirectory ? "folder" : "doc.text").foregroundStyle(.secondary).frame(width: 22)
                Text(file.name).font(.subheadline).foregroundStyle(.primary)
                Spacer(minLength: 4)
                if readOnly && !file.isDirectory { Image(systemName: "lock").font(.caption2).foregroundStyle(.secondary) }
                if let entry = file.entry, !entry.isDirectory {
                    Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
        .listRowInsets(EdgeInsets()).arcaneRowSeparators()
    }

    private func navigate(_ path: String) {
        folder = path
        let remembered = bookmarks[path].flatMap { id in entries.first { $0.id == id }?.id }
        let target = remembered.map { "arcane-file-" + $0 } ?? "arcane-file-directory"
        Task { @MainActor in await Task.yield(); scrollToFile(target) }
    }
    private func reload() async {
        guard let projectName, !projectName.isEmpty else { return }
        do {
            await data.load(client: try store.client(), environment: environment, name: projectName, workingDir: workingDir)
            if !Task.isCancelled, !folder.isEmpty, !data.files.contains(where: { $0.isDirectory && $0.id == folder }) { folder = "" }
        } catch { data.fail(error) }
    }
}

private struct ArcaneFileBreadcrumbs: View {
    let rootName: String
    let folder: String
    let navigate: (String) -> Void
    private var components: [String] { folder.split(separator: "/").map(String.init) }
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                Button(rootName) { navigate("") }.disabled(folder.isEmpty)
                ForEach(Array(components.enumerated()), id: \.offset) { index, name in
                    Image(systemName: "chevron.right").font(.caption2)
                    Button(name) { navigate(components.prefix(index + 1).joined(separator: "/")) }
                        .disabled(index == components.count - 1)
                }
            }.font(.caption).buttonStyle(.borderless).frame(minHeight: 32)
        }.scrollIndicators(.hidden)
    }
}

struct ArcaneProjectFileEditor: View {
    @ObservedObject var store: ArcaneStore
    let environment: String
    let project: ArcaneProjectDocument
    let initialFile: ArcaneProjectFile
    let onSaved: () -> Void
    var body: some View {
        NavigationStack {
            ArcaneProjectFileDocument(store: store, environment: environment, project: project,
                file: initialFile, onSaved: onSaved)
        }
    }
}

private struct ArcaneProjectFileDocument: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: ArcaneStore
    let environment: String
    let project: ArcaneProjectDocument
    let file: ArcaneProjectFile
    let onSaved: () -> Void
    @StateObject private var data = ArcaneFileEditorData()
    @State private var pending: FileAction?
    @State private var readID = UUID()
    @State private var pasteError: String?
    private enum FileAction { case close, reload }
    private var canEdit: Bool { data.editable && !data.loading && !data.saving }
    private var canSave: Bool {
        data.editable && data.dirty && !data.loading && !data.saving && !data.uncertain
            && !store.operationRunning && !store.fileSaveRunning && store.pending == nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            messages
            Divider()
            if data.loading {
                ProgressView("正在读取文件…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if data.viewable {
                ArcaneCodeEditor(text: $data.draft, filename: file.relativePath, editable: data.editable, saving: data.saving)
            } else {
                ContentUnavailableView("无法预览内容", systemImage: "doc",
                    description: Text(data.readOnlyReason ?? data.error ?? "此文件不支持文本预览。"))
            }
        }.privacySensitive().navigationBarTitleDisplayMode(.inline)
        .toolbar { editorToolbar }
        .alert("当前文件有未保存的修改", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { action in
            if canSave { Button("保存并继续") { Task { await save(then: action) } } }
            Button("放弃修改", role: .destructive) { perform(action) }
            Button("继续编辑", role: .cancel) { pending = nil }
        } message: { _ in
            Text(data.uncertain ? "保存结果尚未确认。请重新读取服务器文件核对，或放弃当前草稿。" : "保存后继续，或放弃当前文件的修改。")
        }
        .alert("无法覆盖粘贴", isPresented: Binding(get: { pasteError != nil }, set: { if !$0 { pasteError = nil } })) {
            Button("好", role: .cancel) { pasteError = nil }
        } message: { Text(pasteError ?? "") }
        .task(id: readID) { await load() }
        .interactiveDismissDisabled(data.dirty || data.saving || data.uncertain)
    }

    @ToolbarContentBuilder private var editorToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button { request(.close) } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("返回项目文件").disabled(data.saving)
        }
        ToolbarItem(placement: .principal) {
            Text(file.name).font(.subheadline.weight(.semibold)).lineLimit(1)
        }
        ToolbarItem(placement: .confirmationAction) {
            Button { Task { await save() } } label: {
                if data.saving { ProgressView() } else { Text("保存") }
            }.disabled(!canSave).accessibilityLabel("保存文件")
        }
        ToolbarItem(placement: .bottomBar) { Spacer() }
        ToolbarItem(placement: .bottomBar) {
            Button { pasteOverFile() } label: { Text("覆盖粘贴") }
                .disabled(!canEdit).accessibilityHint("用剪贴板文本替换整个文件的草稿，点击保存后写入服务器")
        }.sharedBackgroundVisibility(.visible)
    }
    private var messages: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(file.relativePath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if !data.viewable, !data.mimeType.isEmpty { Text(data.mimeType).foregroundStyle(.secondary) }
            if let reason = data.readOnlyReason { Text(reason).foregroundStyle(.secondary) }
            if let error = data.error { Text(error).foregroundStyle(.orange) }
            if data.error != nil {
                Button("重新读取服务器文件") { request(.reload) }.disabled(data.loading || data.saving)
            }
            if let notice = data.notice { Text(notice).foregroundStyle(.green) }
        }.font(.footnote).padding(.horizontal, 16).padding(.vertical, 8)
    }
    private func pasteOverFile() {
        guard canEdit else { return }
        guard let contents = UIPasteboard.general.string else {
            pasteError = "剪贴板中没有可读取的文本，文件内容未改变。"
            return
        }
        data.draft = contents
    }
    private func request(_ action: FileAction) {
        if data.dirty || data.uncertain { pending = action } else { perform(action) }
    }
    private func perform(_ action: FileAction) {
        pending = nil
        switch action {
        case .close: dismiss()
        case .reload: readID = UUID()
        }
    }
    private func save(then action: FileAction? = nil) async {
        pending = nil
        await data.save(store: store, environment: environment, project: project, file: file)
        if data.notice != nil { onSaved(); if let action { perform(action) } }
    }
    private func load() async {
        do { await data.load(client: try store.client(), environment: environment, project: project, file: file) }
        catch { data.fail(error) }
    }
}
