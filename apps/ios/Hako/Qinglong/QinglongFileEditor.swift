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
    @State private var running = false
    @State private var scriptPID: Int?
    @State private var runMessage: String?
    @State private var discarding = false
    private var writable: Bool { item.resource != .logs }
    private var changed: Bool { creating ? !text.isEmpty || !filename.isEmpty : baseline != nil && baseline != text }
    private var target: QinglongItem {
        creating ? QinglongItem(resource: .scripts, raw: .fields(["title": filename, "parent": directory])) : item
    }

    var body: some View {
        Group {
            if creating { NavigationStack { editor } }
            else { editor }
        }
        .task(id: store.revision) {
            if creating { loadedRevision = store.revision }
            else if loadedRevision == nil { await load() }
        }
        .confirmationDialog("删除「\(item.title)」？此操作无法撤销。", isPresented: $deleting, titleVisibility: .visible) {
            Button("删除脚本", role: .destructive) { Task { if await store.delete(item) { dismiss() } } }
        }
        .confirmationDialog("运行「\(item.title)」的已保存版本？", isPresented: $running, titleVisibility: .visible) {
            Button("运行已保存版本") { Task { await run() } }
        } message: { Text("使用面板的脚本调试接口执行；编辑器中尚未保存的修改不会参与运行。") }
        .confirmationDialog("放弃未保存的修改？", isPresented: $discarding, titleVisibility: .visible) {
            Button("放弃修改", role: .destructive) { dismiss() }
        }
        .interactiveDismissDisabled(changed || store.busy)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            if creating {
                VStack(spacing: 10) {
                    QinglongTextField("文件名", text: $filename)
                    QinglongTextField("相对目录", text: $directory)
                }.padding().background(Color(uiColor: .secondarySystemGroupedBackground))
            } else {
                Text(item.filePath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).padding(.horizontal).padding(.vertical, 8)
            }
            if loading { ProgressView("正在读取…").padding() }
            if let error { Label(error, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.orange).padding() }
            if let runMessage { Text(runMessage).font(.footnote).textSelection(.enabled).padding() }
            if writable {
                Text("\(item.resource == .configs ? "配置内容" : "脚本内容")\(changed ? " · 未保存" : "")").font(.subheadline).foregroundStyle(.secondary).padding(.horizontal).padding(.top, 8)
                TextEditor(text: $text)
                    .font(.body.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityLabel(item.resource == .configs ? "配置文件内容" : "脚本内容")
                    .disabled(loading || store.busy || !creating && baseline == nil)
                    .padding(.horizontal, 8)
            } else {
                ScrollView { Text(text.isEmpty ? "暂无内容" : text).font(.footnote.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }
            }
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle(creating ? "新建脚本" : item.title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if creating {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { if changed { discarding = true } else { dismiss() } }.disabled(store.busy) }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if writable {
                    Button("保存") { Task { await save() } }.disabled(store.busy || loading || !creating && baseline == nil)
                }
                if !creating {
                    Menu {
                        Button("重新读取", systemImage: "arrow.clockwise") { Task { await load(preserveDraft: true) } }
                        if item.resource == .scripts {
                            Button("运行已保存版本", systemImage: "play") { running = true }.disabled(baseline == nil || scriptPID != nil)
                            if scriptPID != nil { Button("停止调试", systemImage: "stop") { Task { await stop() } } }
                            Button("删除脚本", systemImage: "trash", role: .destructive) { deleting = true }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }.disabled(store.busy || loading || loadedRevision != store.revision)
                    .accessibilityLabel("文件操作")
                }
            }
        }
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
    private func run() async {
        guard loadedRevision == store.revision else { error = "连接已改变，请重新打开文件。"; return }
        let result = await store.perform(.scripts, success: "脚本调试请求已提交，返回成功不代表执行完成。") { api in
            let saved = try await api.file(item)
            let root = try await api.call(["scripts", "run"], method: "PUT", body: .fields(["filename": item.filename, "path": item.directory, "content": saved]))
            scriptPID = root["data"].int
        }
        if result { runMessage = "调试请求已提交\(scriptPID.map { " · PID \($0)" } ?? "")。执行输出可在青龙面板查看；任务执行及日志请使用任务页。" }
        else { error = store.message }
    }
    private func stop() async {
        var body: [String: QinglongJSON] = ["filename": .string(item.filename), "path": .string(item.directory)]
        if let scriptPID { body["pid"] = .number(Double(scriptPID)) }
        let payload = QinglongJSON.object(body)
        let result = await store.perform(.scripts, success: "停止调试请求已提交。") { _ = try await $0.call(["scripts", "stop"], method: "PUT", body: payload) }
        if result { scriptPID = nil; runMessage = "停止请求已提交，请在面板核对执行状态。" } else { error = store.message }
    }
}
