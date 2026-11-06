import SwiftUI

private enum QinglongScriptDestination: Identifiable {
    case create(String), createDirectory(String), edit(QinglongItem), run(QinglongItem), move(QinglongItem)
    var id: String {
        switch self {
        case .create(let path): return "create:" + path
        case .createDirectory(let path): return "create-directory:" + path
        case .edit(let item): return "edit:" + item.id
        case .run(let item): return "run:" + item.id
        case .move(let item): return "move:" + item.id
        }
    }
}

struct QinglongScriptBrowser: View {
    @ObservedObject var store: QinglongStore
    var active: Bool
    let configure: () -> Void
    @State private var directory = ""
    @State private var search = ""
    @State private var destination: QinglongScriptDestination?
    @State private var renameItem: QinglongItem?
    @State private var renameText = ""
    @State private var showRename = false
    @State private var deleteItem: QinglongItem?
    @State private var showDelete = false
    @State private var error: String?
    private var entries: [QinglongItem] { store.items[.scripts] ?? [] }
    private var children: [QinglongItem] { QinglongScriptTree.children(entries, directory: directory) }
    private var filtered: [QinglongItem] { children.filter { search.isEmpty || $0.filename.localizedCaseInsensitiveContains(search) } }
    private struct RefreshKey: Equatable { let active: Bool; let revision: UUID }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if store.connection == nil {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("连接你的青龙面板").font(.headline)
                        Button("配置连接", action: configure).buttonStyle(QinglongPrimaryButtonStyle())
                    }.qinglongCard()
                } else {
                    searchField
                    HStack {
                        Text("脚本管理").font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Menu {
                            Button("新建脚本", systemImage: "doc.badge.plus") { destination = .create(directory) }
                            Button("新建文件夹", systemImage: "folder.badge.plus") { destination = .createDirectory(directory) }
                        } label: { Label("新建", systemImage: "plus") }
                            .buttonStyle(QinglongPrimaryButtonStyle(compact: true)).disabled(store.busy).accessibilityLabel("新建脚本或文件夹")
                    }
                    QinglongScriptBreadcrumb(directory: directory, select: navigate)
                    Text("\(children.filter(\.isDirectory).count) 个文件夹 · \(children.filter { !$0.isDirectory }.count) 个脚本")
                        .font(.caption).foregroundStyle(QinglongStyle.muted)
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Divider().padding(.leading, 52).padding(.trailing, 16) }
                            row(item)
                        }
                    }.qinglongCard(padding: 0, cornerRadius: 16)
                    if store.loading.contains(.scripts) { ProgressView("正在读取脚本…").frame(maxWidth: .infinity).padding() }
                    if filtered.isEmpty && !store.loading.contains(.scripts) && store.errors[.scripts] == nil {
                        ContentUnavailableView(search.isEmpty ? "此目录为空" : "没有匹配的文件", systemImage: "folder")
                    }
                    if let message = store.errors[.scripts] {
                        QinglongNotice(text: message, error: true)
                        Button("重新读取") { Task { await store.refresh(.scripts) } }.buttonStyle(QinglongSecondaryButtonStyle())
                    }
                    if let time = store.updated[.scripts] { Text("\(time.formatted(date: .omitted, time: .standard)) 更新").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity) }
                }
                if let message = store.configurationError { QinglongNotice(text: message, error: true) }
            }.padding(.horizontal, 20).padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationBarBackButtonHidden(!directory.isEmpty)
        .toolbar {
            if !directory.isEmpty {
                ToolbarItem(placement: .topBarLeading) {
                    Button { navigate(QinglongScriptTree.parent(directory)) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("返回上一级目录")
                }
            }
        }
        .refreshable { await store.refresh(.scripts) }
        .task(id: RefreshKey(active: active && destination == nil, revision: store.revision)) {
            guard active, destination == nil, store.connection != nil else { return }
            await store.refresh(.scripts)
        }
        .onChange(of: store.revision) { _, _ in directory = ""; search = ""; destination = nil; showRename = false; showDelete = false; renameItem = nil; deleteItem = nil }
        .onChange(of: entries) { _, _ in
            guard store.errors[.scripts] == nil, store.items[.scripts] != nil else { return }
            directory = QinglongScriptBreadcrumb.existing(directory, entries: entries)
        }
        .sheet(item: $destination) { target in
            switch target {
            case .create(let path): QinglongNewScriptFlow(store: store, directory: path, onCreated: navigate)
            case .createDirectory(let path): QinglongNewScriptDirectory(store: store, directory: path) { navigate(path) }
            case .edit(let item): QinglongFileEditor(store: store, item: item)
            case .run(let item): QinglongScriptRunner(store: store, item: item)
            case .move(let item):
                QinglongScriptDirectoryPicker(store: store, directory: item.directory, excluding: item, confirmTitle: "移动到这里") { path in
                    await store.relocateScript(item, name: item.filename, directory: path)
                }
            }
        }
        .alert("重命名", isPresented: $showRename) {
            TextField("名称", text: $renameText).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("名称")
            Button("取消", role: .cancel) { renameItem = nil }
            Button("保存") { rename() }.disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.busy)
        } message: { Text("名称") }
        .hakoDeleteConfirmation(deleteItem?.isDirectory == true ? Text("删除文件夹及其中的全部内容？") : Text("删除此脚本？"),
                                isPresented: $showDelete, message: deleteItem.map { Text($0.filePath) },
                                confirmTitle: Text("删除"), disabled: store.busy,
                                onDismiss: { deleteItem = nil }, confirm: remove)
        .alert("操作未完成", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好", role: .cancel) {} } message: { Text(error ?? "") }
    }
    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索当前目录", text: $search).font(.subheadline).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("搜索当前目录")
            if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.accessibilityLabel("清除搜索") }
        }.padding(.horizontal, 12).frame(minHeight: 44).background(QinglongStyle.surface, in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(QinglongStyle.line, lineWidth: 1) }
    }
    private func row(_ item: QinglongItem) -> some View {
        HStack(spacing: 0) {
            Button {
                if item.isDirectory { navigate(item.filePath) } else { destination = .edit(item) }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: item.isDirectory ? "folder" : "doc.text").font(.system(size: 20)).foregroundStyle(item.isDirectory ? QinglongStyle.success : QinglongStyle.muted).frame(width: 24)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.filename).font(.system(size: 14, weight: .medium)).foregroundStyle(QinglongStyle.text).multilineTextAlignment(.leading)
                        if item.isDirectory { Text("\(entries.filter { $0.directory == item.filePath }.count) 项").font(.system(size: 11)).foregroundStyle(QinglongStyle.muted) }
                    }
                    Spacer(minLength: 0)
                    if item.isDirectory { Image(systemName: "chevron.right").font(.caption).foregroundStyle(QinglongStyle.muted) }
                }.padding(.leading, 16).padding(.vertical, 13).frame(maxWidth: .infinity, minHeight: 64, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if !item.isDirectory {
                Button { destination = .run(item) } label: { Image(systemName: "play").font(.system(size: 14)).frame(width: 36, height: 44) }
                    .buttonStyle(.plain).accessibilityLabel("运行 " + item.filename).disabled(store.busy)
            }
            Menu {
                Button("重命名", systemImage: "pencil") { renameItem = item; renameText = item.filename; showRename = true }
                Button("移动", systemImage: "folder") { destination = .move(item) }
                Button("删除", systemImage: "trash", role: .destructive) { deleteItem = item; showDelete = true }
            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle()) }
                .accessibilityLabel(item.filename + "，更多操作").disabled(store.busy)
        }.padding(.trailing, 8)
    }
    private func navigate(_ path: String) { directory = path; search = "" }
    private func rename() {
        guard let item = renameItem, !store.busy else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines), revision = store.revision
        do { _ = try QinglongScriptTree.destination(for: item, name: name, directory: item.directory, entries: entries) }
        catch { self.error = error.localizedDescription; return }
        Task {
            guard revision == store.revision else { return }
            let success = await store.relocateScript(item, name: name, directory: item.directory)
            guard revision == store.revision else { return }
            if !success { error = store.message ?? "重命名未完成，请刷新列表。"; await store.refresh(.scripts) }
        }
    }
    private func remove() {
        guard let item = deleteItem, !store.busy else { return }
        let revision = store.revision
        Task {
            guard revision == store.revision else { return }
            let success = await store.delete(item)
            guard revision == store.revision else { return }
            if !success { error = store.message ?? "删除未完成，请刷新列表。"; await store.refresh(.scripts) }
        }
    }
}

private struct QinglongNewScriptDirectory: View {
    @ObservedObject var store: QinglongStore
    let directory: String
    let onCreated: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var revision: UUID
    @State private var name = ""
    @State private var working = false
    @State private var error: String?
    init(store: QinglongStore, directory: String, onCreated: @escaping () -> Void) {
        self.store = store; self.directory = directory; self.onCreated = onCreated
        _revision = State(initialValue: store.revision)
    }
    private var blocked: Bool { working || store.busy || revision != store.revision || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    QinglongTextField("文件夹名称", text: $name)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("创建位置").font(.subheadline).foregroundStyle(.secondary)
                        Text(directory.isEmpty ? "根目录" : directory).textSelection(.enabled)
                    }
                }.disabled(working || store.busy || revision != store.revision)
                if revision != store.revision { QinglongNotice(text: "连接已改变，请关闭后重新创建文件夹。", error: true) }
                else if let error { QinglongNotice(text: error, error: true) }
            }
            .navigationTitle("新建文件夹").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(working) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: create) { if working { ProgressView() } else { Text("创建") } }.disabled(blocked)
                }
            }
        }.tint(QinglongStyle.text).presentationDetents([.medium, .large]).interactiveDismissDisabled(working)
    }
    private func create() {
        guard !blocked else { return }
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try QinglongParsing.file(value, directory: directory)
            try QinglongScriptTree.path(value, allowsRoot: false)
            try QinglongScriptTree.path(directory)
        } catch { self.error = error.localizedDescription; return }
        working = true; error = nil
        Task {
            defer { working = false }
            guard revision == store.revision else { return }
            let success = await store.createScriptDirectory(name: value, directory: directory)
            guard revision == store.revision else { return }
            if success { onCreated(); dismiss() }
            else { error = store.message ?? "创建未完成，请刷新目录后核对。"; await store.refresh(.scripts) }
        }
    }
}

struct QinglongScriptBreadcrumb: View {
    let directory: String
    let select: (String) -> Void
    private var components: [String] { directory.split(separator: "/").map(String.init) }
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button { select("") } label: { Label("根目录", systemImage: "folder") }
                ForEach(Array(components.enumerated()), id: \.offset) { index, name in
                    Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.secondary)
                    Button(name) { select(components.prefix(index + 1).joined(separator: "/")) }
                }
            }.font(.caption).buttonStyle(.plain).frame(minHeight: 36)
        }
        .accessibilityLabel("当前目录：" + (directory.isEmpty ? "根目录" : directory))
    }
    static func existing(_ path: String, entries: [QinglongItem]) -> String {
        var value = path
        while !value.isEmpty && !entries.contains(where: { $0.isDirectory && $0.filePath == value }) { value = QinglongScriptTree.parent(value) }
        return value
    }
}

struct QinglongScriptDirectoryPicker: View {
    @ObservedObject var store: QinglongStore
    let excluding: QinglongItem?
    let confirmTitle: String
    let select: (String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var directory: String
    @State private var revision: UUID
    @State private var working = false
    @State private var error: String?
    @State private var ready = false
    @State private var loading = true
    init(store: QinglongStore, directory: String, excluding: QinglongItem? = nil, confirmTitle: String = "选择此目录", select: @escaping (String) async -> Bool) {
        self.store = store; self.excluding = excluding; self.confirmTitle = confirmTitle; self.select = select
        _directory = State(initialValue: directory); _revision = State(initialValue: store.revision)
    }
    private var entries: [QinglongItem] { store.items[.scripts] ?? [] }
    private var folders: [QinglongItem] {
        QinglongScriptTree.children(entries, directory: directory).filter { entry in
            entry.isDirectory && !(excluding.map { $0.isDirectory && QinglongScriptTree.contains(entry.filePath, in: $0.filePath) } ?? false)
        }
    }
    private var blocked: Bool { !ready || working || store.busy || revision != store.revision || store.errors[.scripts] != nil || store.loading.contains(.scripts) || excluding?.directory == directory }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let excluding { Text(excluding.filename).font(.headline) }
                    QinglongScriptBreadcrumb(directory: directory) { directory = $0; error = nil }
                    VStack(spacing: 0) {
                        ForEach(Array(folders.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Divider().padding(.leading, 52).padding(.trailing, 16) }
                            QinglongPageLink(title: item.filename, symbol: "folder", last: true) { directory = item.filePath; error = nil }
                        }
                    }.qinglongCard(padding: 0)
                    if loading || store.loading.contains(.scripts) { ProgressView("正在读取目录…").frame(maxWidth: .infinity) }
                    else if folders.isEmpty { Text("没有可进入的子目录").font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 24) }
                    if revision != store.revision { QinglongNotice(text: "连接已改变，请关闭后重新选择目录。", error: true) }
                    if let message = error ?? store.errors[.scripts] {
                        QinglongNotice(text: message, error: true)
                        Button("刷新目录") { Task { await reload() } }.buttonStyle(QinglongSecondaryButtonStyle()).disabled(working || revision != store.revision)
                    }
                }.padding(20)
            }.background(QinglongStyle.background)
                .safeAreaInset(edge: .bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("目标：" + (directory.isEmpty ? "根目录" : directory)).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        Button(action: confirm) {
                            HStack { if working { ProgressView() }; Text(confirmTitle) }
                        }.buttonStyle(QinglongPrimaryButtonStyle()).disabled(blocked)
                    }.padding(20).background(QinglongStyle.background)
                }
                .navigationTitle(excluding == nil ? "选择目录" : "移动到").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(working) } }
        }.tint(QinglongStyle.text).interactiveDismissDisabled(working)
            .task { await reload() }
    }
    private func reload() async {
        guard revision == store.revision else { return }
        ready = false; loading = true
        defer { loading = false }
        await store.refresh(.scripts)
        guard !Task.isCancelled, revision == store.revision else { return }
        if store.errors[.scripts] == nil { directory = QinglongScriptBreadcrumb.existing(directory, entries: entries); error = nil; ready = true }
    }
    private func confirm() {
        guard !blocked else { return }
        let path = directory
        working = true; error = nil
        Task {
            guard revision == store.revision else { working = false; return }
            let success = await select(path)
            working = false
            guard revision == store.revision else { return }
            if success { dismiss() }
            else { error = store.message ?? "操作未完成，请刷新目录后重试。"; await store.refresh(.scripts) }
        }
    }
}
