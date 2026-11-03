import SwiftUI

struct QinglongInstancesView: View {
    @ObservedObject var store: QinglongStore
    @Environment(\.dismiss) private var dismiss
    @State private var editing: QinglongConnection?
    @State private var error: String?
    var body: some View {
        QinglongSheet("切换面板", disabled: store.busy) {
            VStack(spacing: 0) {
                ForEach(store.configuration.connections) { connection in
                    Button {
                        do { try store.select(connection.id); dismiss() } catch { self.error = error.localizedDescription }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "server.rack")
                            Text(connection.name).font(.subheadline)
                            Spacer()
                            Image(systemName: connection.id == store.connection?.id ? "checkmark" : "chevron.right").font(.caption)
                        }.padding(16).frame(minHeight: 52).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(store.busy)
                }
            }.qinglongCard(padding: 0)
            Button("添加面板") { editing = QinglongConnection() }.buttonStyle(QinglongSecondaryButtonStyle())
            if let error { QinglongNotice(text: error, error: true) }
        }.sheet(item: $editing) { QinglongConnectionEditor(store: store, initial: $0) }
    }
}

struct QinglongConnectionEditor: View {
    @ObservedObject var store: QinglongStore
    @Environment(\.dismiss) private var dismiss
    let embedded: Bool
    @State private var draft: QinglongConnection
    @State private var testing = false
    @State private var headersEnabled: Bool
    @State private var testResult: String?
    @State private var error: String?
    @State private var deleting = false
    init(store: QinglongStore, initial: QinglongConnection, embedded: Bool = false) {
        self.store = store; self.embedded = embedded; _draft = State(initialValue: initial)
        _headersEnabled = State(initialValue: !initial.headers.isEmpty)
    }
    var body: some View {
        QinglongSheet("连接设置", disabled: testing || store.busy, embedded: embedded, save: save) {
            QinglongTextField("连接名称", text: $draft.name)
            QinglongTextField("面板访问地址", text: $draft.address, keyboard: .URL)
            QinglongTextField("Client ID", text: $draft.clientID)
            QinglongTextField("Client Secret", text: $draft.clientSecret, secure: true)
            Toggle("添加自定义请求头", isOn: $headersEnabled).font(.subheadline)
                .onChange(of: headersEnabled) { _, enabled in if enabled && draft.headers.isEmpty { draft.headers.append(QinglongHeader()) } }
            if headersEnabled {
                ForEach($draft.headers) { $header in
                    VStack(alignment: .leading, spacing: 8) {
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 10) {
                                QinglongTextField("Header 名称", text: $header.name)
                                QinglongTextField("Header 值", text: $header.value, secure: true)
                            }
                            VStack { QinglongTextField("Header 名称", text: $header.name); QinglongTextField("Header 值", text: $header.value, secure: true) }
                        }
                        if draft.headers.count > 1 { Button("移除此请求头", role: .destructive) { draft.headers.removeAll { $0.id == header.id } }.font(.caption) }
                    }
                }
                Button("添加另一条请求头", systemImage: "plus") { draft.headers.append(QinglongHeader()) }.buttonStyle(QinglongInlineButtonStyle())
            }
            if draft.address.lowercased().hasPrefix("http://") { Toggle("允许不加密的 HTTP 连接", isOn: $draft.allowHTTP).font(.subheadline) }
            if let testResult { QinglongNotice(text: testResult) }
            if let error { QinglongNotice(text: error, error: true) }
            Button(testing ? "正在测试…" : "测试连接") { test() }.buttonStyle(QinglongSecondaryButtonStyle())
            if store.configuration.connections.contains(where: { $0.id == draft.id }) {
                Button("删除此连接", role: .destructive) { deleting = true }.buttonStyle(QinglongSecondaryButtonStyle(destructive: true))
            }
        }
        .disabled(testing || store.busy)
        .onChange(of: draft) { _, _ in testResult = nil; error = nil }
        .confirmationDialog("删除此连接？", isPresented: $deleting, titleVisibility: .visible) {
            Button("删除", role: .destructive) { do { try store.remove(draft.id); dismiss() } catch { self.error = error.localizedDescription } }
        }
    }
    private func save() {
        do { var value = draft; if !headersEnabled { value.headers = [] }; try store.save(value); dismiss() }
        catch { self.error = error.localizedDescription }
    }
    private func test() {
        testing = true; error = nil; testResult = nil
        Task {
            defer { testing = false }
            do {
                var value = draft; if !headersEnabled { value.headers = [] }
                let api = try QinglongClient(connection: value); try await api.testConnection()
                testResult = "连接成功，应用凭据有效。"
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
    var embedded = false
    @State private var results: [QinglongResource: String] = [:]
    @State private var checking = false
    @State private var visible = false
    var body: some View {
        QinglongSheet("应用权限", embedded: embedded) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(QinglongResource.allCases) { resource in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(resource.title)
                        Text(results[resource] ?? "未检测").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.qinglongCard()
            Text("检测只读取各模块列表，不执行任务或修改数据。").font(.caption).foregroundStyle(.secondary)
            Button(checking ? "正在检测…" : "重新检测") { Task { await check() } }.buttonStyle(QinglongSecondaryButtonStyle()).disabled(checking || store.connection == nil)
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
