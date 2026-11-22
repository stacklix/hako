import SwiftUI

struct WorkshopFilesView: View {
    @StateObject private var client: WorkshopFilesData
    @State private var scope = WorkshopFileScope.all
    @State private var query = ""
    @State private var expanded: Set<String> = []
    @State private var recent: [WorkshopProjectFile] = []
    @State private var showingRecent = false
    @State private var selectedFile: WorkshopProjectFile?

    init(store: WorkshopStore, agent: WorkshopAgent, application: WorkshopApplication) {
        _client = StateObject(wrappedValue: WorkshopFilesData(store: store, agent: agent, application: application))
    }
    private struct Row: Identifiable {
        let file: WorkshopProjectFile
        let depth: Int
        var id: String { file.path }
    }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var rows: [Row] {
        if searching { return filtered(client.searchResults).map { Row(file: $0, depth: 0) } }
        if showingRecent { return filtered(recent).map { Row(file: $0, depth: 0) } }
        if scope == .modified { return client.modified.map { Row(file: $0, depth: 0) } }
        func walk(_ path: String, depth: Int) -> [Row] {
            (client.directories[path] ?? []).flatMap { file -> [Row] in
                [Row(file: file, depth: depth)] + (file.directory && expanded.contains(file.path) ? walk(file.path, depth: depth + 1) : [])
            }
        }
        return walk("", depth: 0)
    }
    private func filtered(_ values: [WorkshopProjectFile]) -> [WorkshopProjectFile] {
        scope == .modified ? values.filter { file in client.modified.contains { $0.path == file.path } } : values
    }
    var body: some View {
        SettingsSheet(title: "文件", closePlacement: .topBarTrailing) {
            VStack(spacing: 0) {
                fileTabs
                Divider()
                fileList
                searchBar
            }
            .background(Color(uiColor: .secondarySystemBackground))
            .task { await client.refresh() }
            .task(id: query) { await client.search(query) }
            .onChange(of: scope) { _, _ in showingRecent = false }
        }
        .sheet(item: $selectedFile, onDismiss: { Task { await client.refresh() } }) { file in
            WorkshopProjectFileEditor(client: client, file: file)
        }
    }
    private var fileTabs: some View {
        HStack(alignment: .bottom, spacing: 26) {
            ForEach(WorkshopFileScope.allCases, id: \.self) { option in
                Button {
                    scope = option
                } label: {
                    Text(option == .modified ? "已修改 · \(client.modified.count)" : option.rawValue)
                        .font(.subheadline)
                        .fontWeight(scope == option ? .semibold : .regular)
                        .foregroundStyle(scope == option ? Color.primary : Color.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minHeight: 44)
                        .overlay(alignment: .bottom) {
                            Capsule().fill(scope == option ? Color.primary : Color.clear).frame(height: 2)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(scope == option ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("文件范围")
    }
    private var fileList: some View {
        List {
            if let error = client.error {
                Section {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                    Button("重新读取") { Task { await refresh() } }
                }
            }
            if client.truncated {
                Text("部分结果未显示。文件较多或有目录无法读取，请缩小搜索范围或展开目录查看。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if client.searching || client.refreshing && rows.isEmpty { ProgressView("正在读取文件…") }
            if showingRecent { Text("最近浏览").font(.caption).foregroundStyle(.secondary) }
            ForEach(rows) { row in fileRow(row) }
            if rows.isEmpty && !client.searching && !client.refreshing && client.error == nil {
                ContentUnavailableView(searching ? "未找到匹配的文件" : showingRecent ? "还没有浏览记录" : scope == .modified ? "没有已修改的文件" : "目录为空",
                    systemImage: searching ? "doc.text.magnifyingglass" : "folder")
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 44)
        .listRowSpacing(0)
        .contentMargins(.vertical, 0, for: .scrollContent)
        .refreshable { await refresh() }
        .scrollDismissesKeyboard(.interactively)
    }
    private func fileRow(_ row: Row) -> some View {
        let file = row.file
        let modified = client.modified.first { $0.path == file.path }
        return Button { open(file) } label: {
            HStack(spacing: 10) {
                Group {
                    if file.directory {
                        Image(systemName: expanded.contains(file.path) ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                    } else { Color.clear }
                }.frame(width: 10)
                Image(systemName: file.link ? "link" : file.directory ? (expanded.contains(file.path) ? "folder.fill" : "folder") : "doc.text")
                    .font(.system(size: 20)).frame(width: 22).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name).font(.callout).foregroundStyle(.primary).lineLimit(1)
                    if searching || scope == .modified || showingRecent {
                        Text(file.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if file.link { Text("链接 · 无法编辑").font(.caption).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if client.loadingPaths.contains(file.path) { ProgressView() }
                if let label = (modified ?? file).statusLabel {
                    Text(label).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .padding(.leading, CGFloat(min(row.depth, 7)) * 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(file.link || file.deleted)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
        .accessibilityLabel(file.name + (file.directory ? "，文件夹" : "") + (file.deleted ? "，已删除" : ""))
        .accessibilityValue(file.directory ? (expanded.contains(file.path) ? "已展开" : "已折叠") : file.statusLabel ?? "")
        .accessibilityHint(file.path)
    }
    private var searchBar: some View {
        HStack(spacing: 12) {
            Button { showingRecent.toggle() } label: { Image(systemName: "clock.arrow.circlepath").font(.title3).frame(width: 44, height: 44) }
                .tint(showingRecent ? .primary : .secondary)
                .accessibilityLabel("最近浏览的文件").accessibilityAddTraits(showingRecent ? .isSelected : [])
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索文件", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityLabel("搜索项目文件")
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(minWidth: 32, minHeight: 44) }
                    .accessibilityLabel("清除搜索")
            }
        }
        .padding(.trailing, 16).background(Color(uiColor: .tertiarySystemFill), in: Capsule())
        .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 10)
    }
    private func open(_ file: WorkshopProjectFile) {
        if file.directory {
            if searching || showingRecent {
                query = ""; showingRecent = false; scope = .all
                let parts = file.path.split(separator: "/")
                Task {
                    for index in parts.indices {
                        let path = parts.prefix(index + 1).joined(separator: "/")
                        expanded.insert(path); await client.directory(path)
                    }
                }
            } else if expanded.contains(file.path) { expanded.remove(file.path) }
            else { expanded.insert(file.path); Task { await client.directory(file.path) } }
        } else {
            recent.removeAll { $0.path == file.path }; recent.insert(file, at: 0)
            recent = Array(recent.prefix(12)); selectedFile = file
        }
    }
    private func refresh() async {
        await client.refresh()
        for path in expanded.sorted() { await client.directory(path) }
        if searching { await client.search(query) }
    }
}

private struct WorkshopProjectFileEditor: View {
    @ObservedObject var client: WorkshopFilesData
    let file: WorkshopProjectFile
    @StateObject private var data = WorkshopFileEditorData()
    @Environment(\.dismiss) private var dismiss
    @State private var pending: FileAction?
    @State private var showingPreview = false
    @State private var previewSource: String?
    private enum FileAction { case close, reload }
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(file.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if let reason = data.reason { Text(reason).foregroundStyle(.secondary) }
                    if let error = data.error {
                        Text(error).foregroundStyle(.orange)
                        Button("重新读取电脑文件") { request(.reload) }.disabled(data.loading || data.saving)
                    }
                    if let notice = data.notice { Text(notice).foregroundStyle(.green) }
                    else if data.dirty { Text("未保存的修改").foregroundStyle(.secondary) }
                }.font(.footnote).padding(.horizontal, 16).padding(.vertical, 8)
                Divider()
                if data.loading { ProgressView("正在读取文件…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if data.viewable {
                    ZStack {
                        // Preserve selection, undo history and scrolling while previewing.
                        HakoCodeEditor(text: $data.draft, filename: file.path, editable: data.editable,
                            saving: data.saving, active: !showingPreview)
                            .opacity(showingPreview ? 0 : 1)
                            .allowsHitTesting(!showingPreview)
                            .accessibilityHidden(showingPreview)
                        if let previewSource {
                            WorkshopMarkdownPreview(source: previewSource)
                                .opacity(showingPreview ? 1 : 0)
                                .allowsHitTesting(showingPreview)
                                .accessibilityHidden(!showingPreview)
                        }
                    }
                } else {
                    ContentUnavailableView("无法预览内容", systemImage: "doc",
                        description: Text(data.reason ?? data.error ?? "此文件不支持文本预览。"))
                }
            }
            .privacySensitive().navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { request(.close) } label: { Image(systemName: "chevron.left") }
                        .accessibilityLabel("返回项目文件").disabled(data.saving)
                }
                ToolbarItem(placement: .principal) { Text(file.name).font(.subheadline.weight(.semibold)).lineLimit(1) }
                ToolbarItemGroup(placement: .confirmationAction) {
                    if WorkshopMarkdownDocument.supports(file.path) {
                        Button {
                            if !showingPreview { previewSource = data.draft }
                            showingPreview.toggle()
                        } label: { Image(systemName: showingPreview ? "square.and.pencil" : "book") }
                            .accessibilityLabel(showingPreview ? "编辑 Markdown 源码" : "预览 Markdown")
                            .disabled(data.loading || data.saving || !data.viewable)
                    }
                    Button { Task { await save() } } label: {
                        if data.saving { ProgressView() } else { Image(systemName: "checkmark") }
                    }.disabled(!data.canSave).accessibilityLabel("保存文件")
                }
            }
            .task { await data.load(client, file: file) }
            .alert("当前文件有未保存的修改", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { action in
                if data.canSave { Button("保存并继续") { Task { await save(then: action) } } }
                Button("放弃修改", role: .destructive) { perform(action) }
                Button("继续编辑", role: .cancel) { pending = nil }
            } message: { _ in Text(data.uncertain ? "保存结果尚未确认，请重新读取电脑文件核对，或放弃当前草稿。" : "保存后继续，或放弃当前文件的修改。") }
        }
        .interactiveDismissDisabled(data.dirty || data.saving || data.uncertain)
    }
    private func request(_ action: FileAction) {
        if data.dirty || data.uncertain { pending = action } else { perform(action) }
    }
    private func perform(_ action: FileAction) {
        pending = nil
        switch action {
        case .close: dismiss()
        case .reload:
            showingPreview = false; previewSource = nil
            Task { await data.load(client, file: file) }
        }
    }
    private func save(then action: FileAction? = nil) async {
        pending = nil
        if await data.save(client, file: file) {
            if let action { perform(action) }
        }
    }
}
