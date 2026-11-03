import SwiftUI

struct QinglongConnectionsView: View {
    @ObservedObject var store: QinglongStore
    @Environment(\.dismiss) private var dismiss
    @State private var editing: QinglongConnection?
    @State private var removal: QinglongConnection?
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                Section("已保存的面板") {
                    ForEach(store.configuration.connections) { connection in
                        Button { editing = connection } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(connection.name).foregroundStyle(.primary)
                                    Text(HakoLog.safeURL(connection.address)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if connection.id == store.connection?.id { Image(systemName: "checkmark").foregroundStyle(.primary) }
                            }
                        }.disabled(store.busy)
                        .swipeActions {
                            Button("删除", role: .destructive) { removal = connection }.disabled(store.busy)
                        }
                    }
                    Button("添加面板", systemImage: "plus") { editing = QinglongConnection() }.disabled(store.busy)
                }
                if let error { Section { Text(error).foregroundStyle(.orange) } }
                Section { Text("应用凭据和自定义请求头保存在本机 Keychain，不写入应用日志。").font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle("青龙连接").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
            .sheet(item: $editing) { QinglongConnectionEditor(store: store, initial: $0) }
            .confirmationDialog("删除「\(removal?.name ?? "")」的本机连接？", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), titleVisibility: .visible) {
                Button("删除连接", role: .destructive) {
                    guard let removal else { return }
                    do { try store.remove(removal.id) } catch { self.error = error.localizedDescription }
                    self.removal = nil
                }
            }
        }
    }
}

private struct QinglongConnectionEditor: View {
    @ObservedObject var store: QinglongStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: QinglongConnection
    @State private var testing = false
    @State private var testResult: String?
    @State private var error: String?
    init(store: QinglongStore, initial: QinglongConnection) { self.store = store; _draft = State(initialValue: initial) }
    var body: some View {
        NavigationStack {
            Form {
                Section("面板") {
                    QinglongTextField("连接名称", text: $draft.name)
                    QinglongTextField("面板访问地址", text: $draft.address, keyboard: .URL)
                    Toggle("允许不加密的 HTTP 连接", isOn: $draft.allowHTTP)
                }
                Section("应用凭据") {
                    QinglongTextField("Client ID", text: $draft.clientID)
                    QinglongTextField("Client Secret", text: $draft.clientSecret, secure: true)
                }
                Section {
                    ForEach($draft.headers) { $header in
                        VStack(alignment: .leading, spacing: 12) {
                            QinglongTextField("Header 名称", text: $header.name)
                            QinglongTextField("Header 值", text: $header.value, secure: true)
                            Button("移除此请求头", role: .destructive) { draft.headers.removeAll { $0.id == header.id } }
                        }.padding(.vertical, 6)
                    }
                    Button("添加请求头", systemImage: "plus") { draft.headers.append(QinglongHeader()) }
                } header: { Text("自定义请求头（可选）") }
                Section {
                    Button { test() } label: { HStack { Text("测试连接"); if testing { Spacer(); ProgressView() } } }
                    if let testResult { Text(testResult).font(.footnote).foregroundStyle(.secondary) }
                    if let error { Text(error).font(.footnote).foregroundStyle(.orange) }
                }
            }
            .disabled(testing)
            .onChange(of: draft) { _, _ in testResult = nil; error = nil }
            .navigationTitle("连接设置").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(testing) }
                ToolbarItem(placement: .confirmationAction) { Button("保存") {
                    do { try store.save(draft); dismiss() } catch { self.error = error.localizedDescription }
                }.disabled(testing || store.busy) }
            }
            .interactiveDismissDisabled(testing)
        }
    }
    private func test() {
        testing = true; error = nil; testResult = nil
        Task {
            defer { testing = false }
            do {
                let api = try QinglongClient(connection: draft)
                try await api.testConnection()
                testResult = "连接成功，应用凭据有效。各模块权限可在「更多 → 应用权限」中检测。"
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct QinglongTextField: View {
    let title: String
    @Binding var text: String
    var secure = false
    var keyboard: UIKeyboardType = .default
    init(_ title: String, text: Binding<String>, secure: Bool = false, keyboard: UIKeyboardType = .default) {
        self.title = title; _text = text; self.secure = secure; self.keyboard = keyboard
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            if secure {
                SecureField("", text: $text).accessibilityLabel(title).textContentType(nil)
            } else {
                TextField("", text: $text).keyboardType(keyboard).accessibilityLabel(title)
            }
        }.textInputAutocapitalization(.never).autocorrectionDisabled().padding(.vertical, 4)
    }
}

struct QinglongPermissionsView: View {
    @ObservedObject var store: QinglongStore
    @State private var results: [QinglongResource: String] = [:]
    @State private var checking = false
    @State private var visible = false
    var body: some View {
        List {
            Section {
                ForEach(QinglongResource.allCases) { resource in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(resource.title)
                        Text(results[resource] ?? "未检测").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } footer: { Text("检测只读取各模块列表，不执行任务或修改数据。可读取不代表所有写入操作均已授权。") }
            Button(checking ? "正在检测…" : "重新检测") { Task { await check() } }.disabled(checking || store.connection == nil)
        }
        .navigationTitle("应用权限").navigationBarTitleDisplayMode(.inline)
        .onAppear { visible = true }.onDisappear { visible = false }
        .task(id: store.revision) { await check() }
    }
    private func check() async {
        guard !checking else { return }
        checking = true; results = [:]
        let revision = store.revision
        defer { checking = false }
        do {
            let client = try store.client()
            for resource in QinglongResource.allCases {
                guard !Task.isCancelled, visible, revision == store.revision else { return }
                do { _ = try await client.list(resource); if revision == store.revision { results[resource] = "可读取" } }
                catch { if revision == store.revision { results[resource] = error.localizedDescription } }
            }
        } catch { for resource in QinglongResource.allCases { results[resource] = error.localizedDescription } }
    }
}
