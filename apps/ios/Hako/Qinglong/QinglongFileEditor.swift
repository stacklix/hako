import SwiftUI

struct QinglongNewScriptFlow: View {
    @ObservedObject var store: QinglongStore
    @Environment(\.dismiss) private var dismiss
    @State private var filename = ""
    @State private var directory = ""
    @State private var error: String?
    @State private var target: QinglongItem?
    @State private var openedRevision: UUID
    init(store: QinglongStore) {
        self.store = store
        _openedRevision = State(initialValue: store.revision)
    }
    private var connectionChanged: Bool { openedRevision != store.revision }
    var body: some View {
        Group {
            if let target {
                QinglongFileEditor(store: store, item: target, creating: true)
            } else {
                NavigationStack {
                    Form {
                        Section {
                            QinglongTextField("文件名", text: $filename)
                            QinglongTextField("路径", text: $directory)
                        } footer: {
                            Text("路径为脚本相对目录，留空表示根目录。")
                        }.disabled(store.busy || connectionChanged)
                        if connectionChanged { QinglongNotice(text: "连接已改变，请关闭后重新新建脚本。", error: true) }
                        else if let error { QinglongNotice(text: error, error: true) }
                    }
                    .navigationTitle("新建脚本").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("下一步", action: continueEditing)
                                .disabled(filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.busy || connectionChanged)
                        }
                    }
                }
            }
        }
        .tint(QinglongStyle.text)
        .presentationDetents(target == nil ? [.medium, .large] : [.large])
    }
    private func continueEditing() {
        guard !connectionChanged, !store.busy else { return }
        let name = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try QinglongParsing.file(name, directory: path)
            target = QinglongItem(resource: .scripts, raw: .fields(["title": name, "parent": path]))
        } catch { self.error = error.localizedDescription }
    }
}

struct QinglongFileEditor: View {
    @ObservedObject var store: QinglongStore
    let item: QinglongItem
    var creating = false
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var baseline: String?
    @State private var error: String?
    @State private var loading = false
    @State private var loadedRevision: UUID?
    @State private var deleting = false
    @State private var pending: FileAction?
    @State private var notice: String?
    @State private var openedRevision: UUID
    private enum FileAction { case close, reload }
    init(store: QinglongStore, item: QinglongItem, creating: Bool = false) {
        self.store = store; self.item = item; self.creating = creating
        _openedRevision = State(initialValue: store.revision)
    }
    private var writable: Bool { item.resource != .logs }
    private var changed: Bool { creating || baseline != nil && baseline != text }
    private var canSave: Bool {
        writable && changed && !loading && !store.busy && loadedRevision == store.revision && openedRevision == store.revision
            && (!creating || !item.filename.isEmpty)
    }

    var body: some View {
        editor
        .task(id: store.revision) {
            guard openedRevision == store.revision else { error = "连接已改变，请重新打开文件。"; return }
            if creating { loadedRevision = store.revision }
            else if loadedRevision == nil { await load() }
        }
        .confirmationDialog("删除「\(item.title)」？此操作无法撤销。", isPresented: $deleting, titleVisibility: .visible) {
            Button("删除脚本", role: .destructive) {
                Task {
                    guard openedRevision == store.revision else { error = "连接已改变，请重新打开文件。"; return }
                    if await store.delete(item) { dismiss() }
                }
            }
        }
        .alert("当前文件有未保存的修改", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { action in
            if canSave {
                Button("保存并继续") {
                    Task { pending = nil; if await save() { if creating { dismiss() } else { perform(action) } } }
                }
            }
            Button("放弃修改", role: .destructive) { perform(action) }
            Button("继续编辑", role: .cancel) { pending = nil }
        } message: { _ in
            Text("保存后继续，或放弃当前文件的修改。")
        }
        .interactiveDismissDisabled(changed || store.busy)
    }

    @State private var showRunner = false
    private var editor: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                messages
                Divider()
                if loading {
                    ProgressView("正在读取文件…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if creating || baseline != nil {
                    ArcaneCodeEditor(text: $text, filename: item.filePath,
                        editable: writable && openedRevision == store.revision, saving: store.busy)
                } else {
                    ContentUnavailableView("无法读取文件", systemImage: "doc", description: Text(error ?? "请重新读取文件内容。"))
                }
            }
            .privacySensitive().navigationBarTitleDisplayMode(.inline)
            .toolbar { editorToolbar }
        }.tint(QinglongStyle.text)
            .sheet(isPresented: $showRunner) { QinglongScriptRunner(store: store, item: item) }
    }

    @ToolbarContentBuilder private var editorToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button { request(.close) } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("返回\(item.resource.title)").disabled(store.busy)
        }
        ToolbarItem(placement: .principal) {
            Text(item.filename).font(.subheadline.weight(.semibold)).lineLimit(1)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if !creating {
                Menu {
                    Button("重新读取", systemImage: "arrow.clockwise") { request(.reload) }.disabled(loading || openedRevision != store.revision)
                    if item.resource == .scripts {
                        Button("运行已保存脚本", systemImage: "play") { showRunner = true }.disabled(baseline == nil || openedRevision != store.revision)
                        Button("删除脚本", systemImage: "trash", role: .destructive) { deleting = true }.disabled(openedRevision != store.revision)
                    }
                } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel("文件操作").disabled(store.busy)
            }
            if writable {
                Button { Task { if await save(), creating { dismiss() } } } label: {
                    if store.busy { ProgressView() } else { Text("保存") }
                }.disabled(!canSave).accessibilityLabel("保存文件")
            }
        }
    }
    private var messages: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.filePath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if changed { Text("未保存").foregroundStyle(.secondary) }
            if let error { Text(error).foregroundStyle(.orange) }
            if error != nil, !creating {
                Button("重新读取服务器文件") { request(.reload) }.disabled(loading || store.busy || openedRevision != store.revision)
            }
            if let notice { Text(notice).foregroundStyle(QinglongStyle.success) }
        }.font(.footnote).padding(.horizontal, 16).padding(.vertical, 8)
    }
    private func request(_ action: FileAction) {
        if changed { pending = action } else { perform(action) }
    }
    private func perform(_ action: FileAction) {
        pending = nil
        switch action { case .close: dismiss(); case .reload: Task { await load() } }
    }
    private func load() async {
        guard !loading, openedRevision == store.revision else { return }
        loading = true; let revision = store.revision
        defer { loading = false }
        do {
            let result = try await store.client().file(item)
            guard !Task.isCancelled, revision == store.revision else { return }
            text = result; baseline = result; loadedRevision = revision; error = nil; notice = nil
        } catch { if !Task.isCancelled && revision == store.revision { self.error = error.localizedDescription } }
    }
    private func save() async -> Bool {
        guard canSave else { return false }
        let target = item, content = text, previous = baseline, creating = self.creating
        let result = await store.perform(target.resource, success: "文件已保存。") { api in
            try QinglongParsing.file(target.filename, directory: target.directory)
            if creating {
                let files = try await api.list(.scripts)
                guard !files.contains(where: { $0.filePath == target.filePath }) else { throw QinglongFailure(message: "文件已存在，请打开后编辑。") }
            } else {
                let current = try await api.file(target)
                guard current == previous else { throw QinglongFailure(message: "远端文件已修改。本地草稿已保留，请重新打开远端文件比较后保存。") }
            }
            try await api.saveFile(target, content: content, creating: creating)
        }
        if result { baseline = content; error = nil; notice = "文件已保存。" }
        else { error = store.message }
        return result
    }
}
