import SwiftUI

struct ArcaneProjectFilesSection: View {
    @ObservedObject var store: ArcaneStore
    let environment: String
    let projectName: String?
    let workingDir: String?
    let refreshID: UUID
    @StateObject private var data = ArcaneFilesData()
    @State private var folder = ""
    @State private var search = ""
    @State private var selected: ArcaneProjectFile?
    @State private var changed = false
    @State private var reloadID = UUID()

    private var context: String {
        "\(store.connection?.id ?? "")-\(environment)-\(projectName ?? "")-\(workingDir ?? "")-\(refreshID)-\(reloadID)"
    }
    private var entries: [ArcaneProjectFile] {
        data.files.filter {
            search.isEmpty ? ArcaneWorkspacePath.parent($0.relativePath) == folder : $0.relativePath.localizedCaseInsensitiveContains(search)
        }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }

    var body: some View {
        Section {
            if projectName?.isEmpty != false {
                ContentUnavailableView("没有 Compose 项目目录", systemImage: "folder",
                    description: Text("此容器未关联 Compose 项目。项目文件需要先由 Arcane 收录和管理。"))
            } else {
                fileList
            }
        } header: {
            Text("项目文件")
        } footer: {
            Text("显示 Arcane 可访问的项目文件，部分路径可能由服务端隐藏或设为只读。保存文件不会自动执行部署或重启。")
        }
        .task(id: context) { await reload() }
        .sheet(item: $selected, onDismiss: {
            if changed { changed = false; reloadID = UUID() }
        }) { file in
            if let project = data.project {
                ArcaneProjectFileEditor(store: store, environment: environment, project: project, file: file) { changed = true }
            }
        }
    }

    @ViewBuilder private var fileList: some View {
        if let project = data.project {
            VStack(alignment: .leading, spacing: 4) {
                Text(project.name).font(.subheadline.weight(.semibold))
                if let path = project.path { Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }.arcaneRowSeparators()
        }
        if data.loading { ProgressView("正在读取项目文件…").arcaneRowSeparators() }
        if let error = data.error {
            Text(error).font(.footnote).foregroundStyle(.orange).arcaneRowSeparators()
            Button("重新读取目录") { reloadID = UUID() }.arcaneRowSeparators()
        }
        if data.workspace != nil {
            TextField("搜索项目文件", text: $search)
                .textInputAutocapitalization(.never).autocorrectionDisabled().arcaneRowSeparators()
            HStack(spacing: 12) {
                Button { folder = ArcaneWorkspacePath.parent(folder) } label: {
                    Label("上一级", systemImage: "arrow.up").frame(minHeight: 44)
                }.buttonStyle(.borderless).disabled(folder.isEmpty)
                Spacer(minLength: 0)
                Text(folder.isEmpty ? "项目目录" : folder).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }.arcaneRowSeparators()
            if data.workspace?.fileTreeTruncated == true {
                Text("目录超过 Arcane 的文件数量或深度限制，当前列表未完整返回。")
                    .font(.footnote).foregroundStyle(.orange).arcaneRowSeparators()
            }
            if entries.isEmpty { Text("没有符合条件的文件").foregroundStyle(.secondary).arcaneRowSeparators() }
            ForEach(entries) { file in fileRow(file) }
        }
    }

    private func fileRow(_ file: ArcaneProjectFile) -> some View {
        let readOnly = file.entry?.editable == false || (file.kind != .workspace && data.project?.editable(file.kind) == false)
        return Button {
            if file.isDirectory && file.entry?.isSymlink != true { folder = file.relativePath; search = "" }
            else { selected = file }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: file.isDirectory ? "folder" : "doc.text").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(file.name).foregroundStyle(.primary)
                    if !search.isEmpty { Text(file.relativePath).font(.caption).foregroundStyle(.secondary) }
                    if let entry = file.entry, !entry.isDirectory {
                        Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                if readOnly && !file.isDirectory {
                    Image(systemName: "lock").font(.caption).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }.frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .arcaneRowSeparators()
    }

    private func reload() async {
        guard let projectName, !projectName.isEmpty else { return }
        do {
            await data.load(client: try store.client(), environment: environment, name: projectName, workingDir: workingDir)
            if !Task.isCancelled, !folder.isEmpty, !data.files.contains(where: { $0.isDirectory && $0.id == folder }) { folder = "" }
        }
        catch { data.fail(error) }
    }
}

private struct ArcaneProjectFileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: ArcaneStore
    let environment: String
    let project: ArcaneProjectDocument
    let file: ArcaneProjectFile
    let onSaved: () -> Void
    @StateObject private var data = ArcaneFileEditorData()
    @State private var discard: DiscardAction?
    @State private var readID = UUID()
    private enum DiscardAction { case close, reload }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                messages
                if data.loading {
                    ProgressView("正在读取文件…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if data.viewable {
                    if data.editable {
                        TextEditor(text: $data.draft)
                            .font(.system(.body, design: .monospaced))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .disabled(data.saving)
                            .padding(.horizontal, 12)
                            .accessibilityLabel("编辑 \(file.relativePath)")
                    } else {
                        ScrollView {
                            Text(verbatim: data.draft).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding()
                        }
                    }
                } else {
                    ContentUnavailableView("无法预览内容", systemImage: "doc",
                        description: Text(data.readOnlyReason ?? data.error ?? "此文件不支持文本预览。"))
                }
            }
            .privacySensitive()
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { requestDiscard(.close) } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("关闭文件").disabled(data.saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            await data.save(store: store, environment: environment, project: project, file: file)
                            if data.notice != nil { onSaved() }
                        }
                    } label: {
                        if data.saving { ProgressView() } else { Image(systemName: "checkmark") }
                    }
                    .accessibilityLabel(data.saving ? "正在保存文件" : "保存文件")
                    .disabled(!data.editable || !data.dirty || data.loading || data.saving || data.uncertain || store.operationRunning || store.fileSaveRunning || store.pending != nil)
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Text(ByteCountFormatter.string(fromByteCount: data.size, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("重新读取") { requestDiscard(.reload) }.disabled(data.loading || data.saving)
                }
            }
            .alert("放弃当前编辑？", isPresented: Binding(get: { discard != nil }, set: { if !$0 { discard = nil } }), presenting: discard) { action in
                Button("放弃修改", role: .destructive) { perform(action) }
                Button("继续编辑", role: .cancel) { discard = nil }
            } message: { _ in
                Text(data.uncertain ? "保存结果尚未确认。请先在 Arcane 核对；继续此操作将放弃当前草稿。" : "当前修改尚未保存，放弃后无法恢复。")
            }
            .task(id: readID) { await load() }
        }
        .interactiveDismissDisabled(data.dirty || data.saving || data.uncertain)
    }

    @ViewBuilder private var messages: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(file.relativePath).font(.caption).foregroundStyle(.secondary)
            if !data.mimeType.isEmpty { Text(data.mimeType).font(.caption).foregroundStyle(.secondary) }
            if let reason = data.readOnlyReason { Text(reason).foregroundStyle(.secondary) }
            if let error = data.error { Text(error).foregroundStyle(.orange) }
            if let notice = data.notice { Text(notice).foregroundStyle(.green) }
        }.font(.footnote).padding()
    }

    private func requestDiscard(_ action: DiscardAction) {
        if data.dirty || data.uncertain { discard = action } else { perform(action) }
    }
    private func perform(_ action: DiscardAction) {
        discard = nil
        switch action {
        case .close: dismiss()
        case .reload: readID = UUID()
        }
    }
    private func load() async {
        do { await data.load(client: try store.client(), environment: environment, project: project, file: file) }
        catch { data.fail(error) }
    }
}
