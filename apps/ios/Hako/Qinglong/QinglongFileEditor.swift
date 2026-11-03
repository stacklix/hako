import SwiftUI

struct QinglongFileEditor: View {
    @ObservedObject var store: QinglongStore
    let item: QinglongItem
    var creating = false
    @Environment(\.dismiss) private var dismiss
    @State private var filename = ""
    @State private var directory = ""
    @State private var text = ""
    @State private var baseline: String?
    @State private var error: String?
    @State private var loading = false
    @State private var loadedRevision: UUID?
    @State private var deleting = false
    @State private var discarding = false
    private var writable: Bool { item.resource != .logs }
    private var changed: Bool { creating ? !text.isEmpty || !filename.isEmpty : baseline != nil && baseline != text }
    private var target: QinglongItem {
        creating ? QinglongItem(resource: .scripts, raw: .fields(["title": filename, "parent": directory])) : item
    }

    var body: some View {
        editor
        .task(id: store.revision) {
            if creating { loadedRevision = store.revision }
            else if loadedRevision == nil { await load() }
        }
        .confirmationDialog("删除「\(item.title)」？此操作无法撤销。", isPresented: $deleting, titleVisibility: .visible) {
            Button("删除脚本", role: .destructive) { Task { if await store.delete(item) { dismiss() } } }
        }
        .confirmationDialog("放弃未保存的修改？", isPresented: $discarding, titleVisibility: .visible) {
            Button("放弃修改", role: .destructive) { dismiss() }
        }
        .interactiveDismissDisabled(changed || store.busy)
    }

    @State private var showRunner = false
    private var editor: some View {
        QinglongSheet(creating ? "新建脚本" : item.title, disabled: store.busy, saveDisabled: loading || !creating && baseline == nil, close: {
            if changed { discarding = true } else { dismiss() }
        }, save: writable ? { Task { await save() } } : nil) {
            if creating {
                QinglongTextField("文件名", text: $filename)
                QinglongTextField("相对目录", text: $directory)
            } else { Text(item.filePath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            if loading { ProgressView("正在读取…") }
            if let error { QinglongNotice(text: error, error: true) }
            if writable {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(item.resource == .configs ? "配置内容" : "脚本内容")\(changed ? " · 未保存" : "")").font(.subheadline).foregroundStyle(.secondary)
                    TextEditor(text: $text).font(.footnote.monospaced()).frame(minHeight: 280)
                        .scrollContentBackground(.hidden).padding(10)
                        .background(QinglongStyle.surface, in: RoundedRectangle(cornerRadius: 10))
                        .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("文件内容")
                        .disabled(loading || store.busy || !creating && baseline == nil)
                }
            } else { Text(text.isEmpty ? "暂无内容" : text).qinglongCode() }
            if !creating {
                if item.resource == .scripts {
                    Button("运行已保存脚本") { showRunner = true }.buttonStyle(QinglongSecondaryButtonStyle()).disabled(store.busy || baseline == nil)
                    Button("删除脚本", role: .destructive) { deleting = true }.buttonStyle(QinglongSecondaryButtonStyle(destructive: true)).disabled(store.busy)
                }
                Button("重新读取") { Task { await load(preserveDraft: true) } }.buttonStyle(QinglongSecondaryButtonStyle()).disabled(store.busy || loading)
            }
        }.sheet(isPresented: $showRunner) { QinglongScriptRunner(store: store, item: item) }
    }
    private func load(preserveDraft: Bool = false) async {
        if preserveDraft && changed { error = "当前有未保存的修改，请先保存或返回后重新打开文件。"; return }
        loading = true; let revision = store.revision
        defer { loading = false }
        do {
            let result = try await store.client().file(item)
            guard !Task.isCancelled, revision == store.revision else { return }
            text = result; baseline = result; loadedRevision = revision; error = nil
        } catch { if !Task.isCancelled && revision == store.revision { self.error = error.localizedDescription } }
    }
    private func save() async {
        guard loadedRevision == store.revision else { error = "连接已改变，请重新打开文件。"; return }
        let target = self.target, content = text, previous = baseline, creating = self.creating
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
        if result { baseline = text; error = nil; if creating { dismiss() } }
        else { error = store.message }
    }
}
