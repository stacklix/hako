import SwiftUI

struct QinglongSettingsView: View {
    @ObservedObject var store: QinglongStore
    @State private var editing: QinglongConnection?
    @State private var error: String?
    @State private var permissions = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("面板实例").font(.system(size: 14, weight: .semibold))
                VStack(spacing: 0) {
                    ForEach(store.configuration.connections) { connection in
                        Button {
                            do { try store.select(connection.id); error = nil } catch { self.error = error.localizedDescription }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "server.rack").frame(width: 20)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(connection.name).font(.system(size: 13))
                                    Text(connection.id == store.connection?.id ? "当前使用" : "点击切换").font(.caption).foregroundStyle(QinglongStyle.muted)
                                }
                                Spacer()
                                if connection.id == store.connection?.id { Image(systemName: "checkmark").font(.caption).accessibilityHidden(true) }
                            }.padding(16).frame(minHeight: 60).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(store.busy)
                            .accessibilityAddTraits(connection.id == store.connection?.id ? .isSelected : [])
                            .overlay(alignment: .bottom) { Rectangle().fill(QinglongStyle.line).frame(height: 1).padding(.horizontal, 16) }
                    }
                    QinglongMenuRow(title: "添加面板", symbol: "plus", last: true) { editing = QinglongConnection() }
                }.qinglongCard(padding: 0)
                if let connection = store.connection {
                    Text("当前实例").font(.system(size: 14, weight: .semibold))
                    VStack(spacing: 0) {
                        QinglongMenuRow(title: "编辑连接", symbol: "network") { editing = connection }
                        QinglongMenuRow(title: "应用权限", symbol: "checkmark.shield", last: true) { permissions = true }
                    }.qinglongCard(padding: 0).disabled(store.busy)
                }
                if let error { QinglongNotice(text: error, error: true) }
                if let error = store.configurationError {
                    QinglongNotice(text: error, error: true)
                    Button("重新读取连接") { store.load() }.buttonStyle(QinglongSecondaryButtonStyle())
                }
            }.padding(20)
        }.background(QinglongStyle.background).foregroundStyle(QinglongStyle.text).tint(QinglongStyle.text)
            .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
            .sheet(item: $editing) { QinglongConnectionEditor(store: store, initial: $0) }
            .sheet(isPresented: $permissions) { QinglongPermissionsView(store: store) }
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
            Section {
            QinglongTextField("连接名称", text: $draft.name)
            QinglongTextField("面板访问地址", text: $draft.address, keyboard: .URL)
            QinglongTextField("Client ID", text: $draft.clientID)
            QinglongTextField("Client Secret", text: $draft.clientSecret, secure: true)
            }
            Section {
            Toggle("添加自定义请求头", isOn: $headersEnabled).font(.subheadline)
                .onChange(of: headersEnabled) { _, enabled in if enabled && draft.headers.isEmpty { draft.headers.append(QinglongHeader()) } }
            if headersEnabled {
                ForEach($draft.headers) { $header in
                    VStack(alignment: .leading, spacing: 8) {
                        QinglongTextField("Header 名称", text: $header.name)
                        QinglongTextField("Header 值", text: $header.value, secure: true)
                        if draft.headers.count > 1 { Button("移除此请求头", role: .destructive) { draft.headers.removeAll { $0.id == header.id } }.font(.caption) }
                    }
                }
                Button("添加另一条请求头", systemImage: "plus") { draft.headers.append(QinglongHeader()) }.buttonStyle(QinglongInlineButtonStyle())
            }
            if draft.address.lowercased().hasPrefix("http://") { Toggle("允许不加密的 HTTP 连接", isOn: $draft.allowHTTP).font(.subheadline) }
            }
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
