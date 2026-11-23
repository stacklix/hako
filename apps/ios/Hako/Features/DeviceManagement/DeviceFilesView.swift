import SwiftUI

private enum DeviceFileSheet: Identifiable {
    case search(String), editor(DeviceFileEntry), mutation(String, DeviceFileEntry?)
    var id: String {
        switch self {
        case .search(let path): "search:" + path
        case .editor(let file): "editor:" + file.path
        case .mutation(let kind, let file): kind + ":" + (file?.path ?? "")
        }
    }
}

struct DeviceFilesView: View {
    @StateObject private var store: DeviceFilesStore
    @State private var sheet: DeviceFileSheet?
    @State private var acknowledging = false
    init(agent: ConsoleAgent) { _store = StateObject(wrappedValue: DeviceFilesStore(agent: agent)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !store.root.isEmpty {
                Text(store.root).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack(spacing: 4) {
                breadcrumbs
                Spacer(minLength: 0)
                icon("magnifyingglass", "搜索当前目录") { sheet = .search(store.path) }
                    .disabled(store.root.isEmpty)
                icon("arrow.clockwise", "刷新目录") { Task { await store.load() } }.disabled(store.loading)
                Menu {
                    Toggle("显示隐藏项目", isOn: $store.showHidden)
                } label: { Image(systemName: "ellipsis").fileToolbarIcon() }
                    .accessibilityLabel("文件显示选项")
                Menu {
                    Button("新建文件", systemImage: "doc.badge.plus") { sheet = .mutation("createFile", nil) }
                    Button("新建文件夹", systemImage: "folder.badge.plus") { sheet = .mutation("createFolder", nil) }
                } label: { Image(systemName: "plus").fileToolbarIcon() }
                    .disabled(!store.canWrite || store.loading || store.root.isEmpty)
                    .accessibilityLabel("在当前目录新建文件或文件夹")
            }
            if store.loading && store.entries.isEmpty { ProgressView("正在读取目录…").frame(maxWidth: .infinity).padding() }
            if !store.entries.isEmpty {
                LazyVStack(spacing: 0) {
                    ForEach(store.entries) { entry in
                        if entry.id != store.entries.first?.id { Divider() }
                        HStack(spacing: 0) {
                            Button { open(entry) } label: { DeviceFileRow(entry: entry) }
                                .buttonStyle(.plain).disabled(entry.link)
                            Menu {
                                Button("重命名", systemImage: "pencil") { sheet = .mutation("rename", entry) }
                                Button("删除", systemImage: "trash", role: .destructive) { sheet = .mutation("delete", entry) }
                            } label: { Image(systemName: "ellipsis").fileToolbarIcon().foregroundStyle(.secondary) }
                                .disabled(!store.canWrite || entry.link)
                                .accessibilityLabel("\(entry.name) 的操作")
                        }
                    }
                }
                .background(HakoStyle.card, in: RoundedRectangle(cornerRadius: 12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            } else if !store.loading, store.error == nil, !store.root.isEmpty {
                ContentUnavailableView("此目录没有文件", systemImage: "folder")
            }
            if store.nextOffset != nil {
                Button("读取更多文件") { Task { await store.load(more: true) } }.disabled(store.loading)
            }
            HStack {
                Text("\(store.entries.count) 个项目")
                Spacer()
                Text("按名称排序 · 文件夹优先")
            }.font(.caption2).foregroundStyle(.secondary)
            if store.truncated { Text("部分项目无法读取或目录超过 10,000 项，当前列表可能不完整。").font(.footnote).foregroundStyle(.orange) }
            if let error = store.error { Text(error).font(.footnote).foregroundStyle(.orange) }
            if let notice = store.notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
            if store.pendingID != nil {
                Text("上一项操作结果待确认。请先核对，再继续修改文件。").font(.footnote).foregroundStyle(.orange)
                Button("核对操作结果") { Task { await store.resolvePending() } }.disabled(store.writing)
                Button("已手动核对目录…") { acknowledging = true }.font(.footnote)
            }
        }
        .task { if store.root.isEmpty { await store.load() } }
        .onChange(of: store.showHidden) { _, _ in Task { await store.load() } }
        .sheet(item: $sheet) { value in
            switch value {
            case .search(let path):
                DeviceFileSearchSheet(store: store, path: path) { entry in
                    sheet = nil
                    if entry.directory { Task { await store.load(path: entry.path) } }
                }
            case .editor(let entry): DeviceFileEditorSheet(store: store, entry: entry)
            case .mutation(let operation, let entry): DeviceFileMutationSheet(store: store, operation: operation, entry: entry)
            }
        }
        .alert("结束结果核对？", isPresented: $acknowledging) {
            Button("取消", role: .cancel) { }
            Button("已核对，结束等待") { store.acknowledgePending() }
        } message: { Text("仅在已查看电脑文件、确认上次操作的实际结果后结束等待。此操作不会重新执行文件操作。") }
        .privacySensitive()
    }
    private var breadcrumbs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                Button("用户目录") { Task { await store.load(path: "") } }.disabled(store.loading || store.path.isEmpty)
                let components = store.path.split(separator: "/").map(String.init)
                ForEach(Array(components.enumerated()), id: \.offset) { index, name in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                    Button(name) { Task { await store.load(path: components.prefix(index + 1).joined(separator: "/")) } }
                        .disabled(store.loading || index == components.count - 1)
                }
            }.font(.caption).frame(minHeight: 44)
        }.scrollIndicators(.hidden)
    }
    private func icon(_ name: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: name).fileToolbarIcon() }.accessibilityLabel(label)
    }
    private func open(_ entry: DeviceFileEntry) {
        if entry.directory { Task { await store.load(path: entry.path) } }
        else { sheet = .editor(entry) }
    }
}

private extension View {
    func fileToolbarIcon() -> some View { font(.system(size: 17, weight: .regular)).frame(width: 44, height: 44).contentShape(Rectangle()) }
    func fileRowSeparators() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
    }
}

private struct DeviceFileRow: View {
    let entry: DeviceFileEntry
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.link ? "link" : entry.directory ? "folder" : "doc.text")
                .font(.system(size: 21)).foregroundStyle(entry.directory ? Color.accentColor : .secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.name).font(.subheadline).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    if entry.link { Text("链接 · 不可访问") }
                    else if !entry.directory { Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)); Text("·") }
                    Text(Date(timeIntervalSince1970: Double(entry.modifiedAt) / 1000), format: .dateTime.month().day().hour().minute())
                    if entry.readOnly && !entry.directory { Image(systemName: "lock") }
                }.font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 12).padding(.leading, 16).padding(.trailing, 4)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading).contentShape(Rectangle())
    }
}

private struct DeviceFileSearchSheet: View {
    @ObservedObject var store: DeviceFilesStore
    let path: String
    let openFolder: (DeviceFileEntry) -> Void
    @State private var query = ""
    @State private var results: [DeviceFileEntry] = []
    @State private var nextOffset: Int?
    @State private var truncated = false
    @State private var loading = false
    @State private var error: String?
    @State private var editor: DeviceFileEntry?
    @State private var generation = UUID()
    @FocusState private var focused: Bool
    var body: some View {
        SettingsSheet(title: "搜索文件") {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("文件或文件夹名称").font(.subheadline).foregroundStyle(.secondary)
                        TextField("搜索当前目录", text: $query).focused($focused).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityLabel("文件或文件夹名称")
                    }.fileRowSeparators()
                } header: { Text(path.isEmpty ? store.root : path).textCase(nil) }
                Section {
                    if loading && results.isEmpty { ProgressView("正在搜索…").fileRowSeparators() }
                    ForEach(results) { entry in
                        Button {
                            focused = false
                            if entry.directory { openFolder(entry) }
                            else { editor = entry }
                        } label: { DeviceFileRow(entry: entry) }
                            .buttonStyle(.plain).disabled(entry.link).listRowInsets(EdgeInsets()).fileRowSeparators()
                    }
                    if !loading, results.isEmpty, error == nil {
                        Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "输入名称查找文件或文件夹" : "没有匹配的文件")
                            .foregroundStyle(.secondary).fileRowSeparators()
                    }
                    if nextOffset != nil { Button("读取更多结果") { Task { await search(more: true) } }.disabled(loading).fileRowSeparators() }
                    if truncated { Text("目录超过扫描上限或部分项目无法读取，结果可能不完整。").font(.footnote).foregroundStyle(.orange).fileRowSeparators() }
                    if let error { Text(error).font(.footnote).foregroundStyle(.orange).fileRowSeparators() }
                } header: { Text("\(results.count) 个搜索结果") }
            }.task(id: query) {
                generation = UUID(); results = []; nextOffset = nil; error = nil
                guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { loading = false; return }
                do { try await Task.sleep(for: .milliseconds(300)); try Task.checkCancellation(); await search() } catch { }
            }
        }
        .sheet(item: $editor) { entry in DeviceFileEditorSheet(store: store, entry: entry) }
    }
    private func search(more: Bool = false) async {
        let request = generation, term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.count <= 200 else { error = "关键词不能超过 200 个字符。"; loading = false; return }
        loading = true
        defer { if generation == request { loading = false } }
        do {
            let reply = try await store.page(path: path, query: term, offset: more ? nextOffset ?? 0 : 0)
            guard !Task.isCancelled, request == generation else { return }
            results = more ? results + reply.entries.filter { next in !results.contains { $0.id == next.id } } : reply.entries
            nextOffset = reply.nextOffset; truncated = reply.truncated; error = nil
        } catch is CancellationError { }
        catch { if request == generation { self.error = error.localizedDescription } }
    }
}

private struct DeviceFileMutationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: DeviceFilesStore
    let operation: String
    let entry: DeviceFileEntry?
    @State private var name: String
    @State private var error: String?
    @State private var deleteContentHeight: CGFloat = 240
    init(store: DeviceFilesStore, operation: String, entry: DeviceFileEntry?) {
        self.store = store; self.operation = operation; self.entry = entry
        _name = State(initialValue: operation == "rename" ? entry?.name ?? "" : "")
    }
    private var deleting: Bool { operation == "delete" }
    private var title: String {
        switch operation {
        case "createFile": "新建文件"
        case "createFolder": "新建文件夹"
        case "rename": "重命名"
        default: "删除\(entry?.directory == true ? "文件夹" : "文件")"
        }
    }
    private var valid: Bool { deleting || DeviceFilePath.validName(name) && name != (operation == "rename" ? entry?.name : nil) }
    var body: some View {
        SettingsSheet(title: title, hasChanges: !deleting && name != (operation == "rename" ? entry?.name ?? "" : ""),
                      isBusy: store.writing, saveEnabled: valid && store.canWrite,
                      onSave: deleting ? nil : { Task { await submit() } },
                      detents: deleting ? [.height(min(max(deleteContentHeight + 56, 260), 620))] : [.large],
                      saveAccessibilityLabel: operation == "rename" ? "保存名称" : "创建") {
            if deleting {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        location
                        Text("确定删除「\(entry?.name ?? "")」\(entry?.directory == true ? "及其中的全部内容" : "")？此操作无法撤销。")
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 12) {
                            Button("取消") { dismiss() }.buttonStyle(HakoActionButtonStyle(primary: false))
                                .disabled(store.writing)
                            HakoDeleteButton(title: "删除") { Task { await submit() } }
                                .disabled(!store.canWrite)
                        }
                        operationFeedback
                    }
                    .padding(16)
                    .background(HakoStyle.card, in: RoundedRectangle(cornerRadius: 12))
                    .padding(16)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { deleteContentHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .background(HakoStyle.background)
            } else {
                Form {
                    Section {
                        location.fileRowSeparators()
                        VStack(alignment: .leading, spacing: 6) {
                            Text(operation == "createFolder" || entry?.directory == true ? "文件夹名称" : "文件名称").font(.subheadline).foregroundStyle(.secondary)
                            TextField(operation == "createFolder" ? "例如：工作资料" : "例如：notes.md", text: $name)
                                .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("名称")
                        }.fileRowSeparators()
                        if !name.isEmpty, !DeviceFilePath.validName(name) { Text("名称不能包含路径、保留名称或特殊字符。").font(.footnote).foregroundStyle(.orange).fileRowSeparators() }
                        if operation == "createFile" { Text("创建后，打开文件即可编辑内容。").font(.footnote).foregroundStyle(.secondary).fileRowSeparators() }
                        operationFeedback
                    }
                }
            }
        }
    }
    private var location: some View {
        Text(entry?.path ?? (store.path.isEmpty ? store.root : store.path))
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    @ViewBuilder private var operationFeedback: some View {
        if let error { Text(error).font(.footnote).foregroundStyle(.orange).fileRowSeparators() }
        if store.pendingID != nil {
            Button("核对操作结果") { Task { if await store.resolvePending() != nil { dismiss() } } }
                .disabled(store.writing).fileRowSeparators()
        }
    }
    private func submit() async {
        error = nil
        do { try await store.mutate(operation, path: entry?.path ?? store.path, name: deleting ? nil : name, revision: entry?.revision); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

private struct DeviceFileEditorSheet: View {
    @ObservedObject var store: DeviceFilesStore
    let entry: DeviceFileEntry
    @State private var document: DeviceFileDocument?
    @State private var draft = ""
    @State private var original = ""
    @State private var loading = true
    @State private var preview = false
    @State private var error: String?
    @State private var saved = false
    @State private var confirmingReload = false
    private var dirty: Bool { draft != original }
    private var canSave: Bool { document?.editable == true && dirty && store.canWrite && !loading }
    var body: some View {
        SettingsSheet(title: entry.name, hasChanges: dirty, isBusy: store.writing,
                      saveEnabled: canSave, onSave: { Task { await save() } }, saveAccessibilityLabel: "保存文件") {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    HStack {
                        Text(entry.isMarkdown ? "Markdown" : "纯文本").font(.caption).foregroundStyle(.secondary)
                        if let encoding = document?.encoding { Text(encoding.uppercased()).font(.caption2).foregroundStyle(.secondary) }
                        Spacer()
                        Text(dirty ? "未保存" : saved ? "已保存" : "").font(.caption).foregroundStyle(.secondary)
                        if entry.isMarkdown, document?.text != nil {
                            Button { preview.toggle() } label: { Label(preview ? "编辑" : "预览", systemImage: preview ? "pencil" : "eye") }.font(.subheadline).frame(minHeight: 44)
                        }
                    }
                    if let reason = document?.reason { Text(reason).font(.footnote).foregroundStyle(.secondary) }
                    if let error { Text(error).font(.footnote).foregroundStyle(.orange) }
                    if store.pendingID != nil {
                        Button("核对保存结果") { Task { await resolve() } }.disabled(store.writing)
                    }
                    if error != nil { Button("重新读取电脑文件") { confirmingReload = true }.disabled(store.writing) }
                    Text("文件内容").font(.subheadline).foregroundStyle(.secondary)
                }.padding(.horizontal, 16).padding(.vertical, 10)
                Divider()
                if loading { ProgressView("正在读取文件…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if document?.text == nil { ContentUnavailableView("无法预览内容", systemImage: "doc", description: Text(document?.reason ?? error ?? "此文件不支持文本预览。")) }
                else if preview {
                    ScrollView {
                        if let html = AssistantHTML(AssistantMarkdown.render(draft)) { AssistantReplyView(html: html).padding(16) }
                        else { Text(draft.isEmpty ? "暂无内容" : "内容过长，暂不支持 Markdown 预览，请切换到编辑查看。").foregroundStyle(.secondary).padding() }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HakoCodeEditor(text: $draft, filename: entry.name, editable: document?.editable == true && store.pendingID == nil,
                                   saving: store.writing).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.privacySensitive().task { await load() }
        }
        .alert("重新读取电脑文件？", isPresented: $confirmingReload) {
            Button("取消", role: .cancel) { }
            Button("重新读取", role: dirty ? .destructive : nil) { Task { await load() } }
        } message: { Text(dirty ? "当前未保存的草稿会被电脑上的内容替换。" : "读取电脑上的最新文件内容。") }
    }
    private func load() async {
        loading = true; error = nil; defer { loading = false }
        do { let value = try await store.read(entry); document = value; draft = value.text ?? ""; original = draft; saved = false }
        catch { self.error = error.localizedDescription }
    }
    private func save() async {
        guard let document else { return }; error = nil
        let saving = draft
        do { self.document = try await store.save(entry, document: document, text: saving); original = saving; saved = true }
        catch { self.error = error.localizedDescription }
    }
    private func resolve() async {
        if let result = await store.resolvePending(), let encoding = document?.encoding,
           let bytes = DeviceFileDocument.encode(draft, encoding: encoding), result.path == entry.path, result.revision == DeviceFilePath.digest(bytes) {
            document = .init(revision: result.revision, encoding: encoding, editable: true, reason: nil, text: draft)
            original = draft; saved = true; error = nil
        } else { error = store.error ?? "请重新读取电脑文件核对保存结果。" }
    }
}
