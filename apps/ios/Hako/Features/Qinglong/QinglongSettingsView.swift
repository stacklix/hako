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
            Section {
                VStack(spacing: 12) {
                    Button(testing ? "正在测试…" : "测试连接", action: test)
                        .buttonStyle(HakoActionButtonStyle(primary: false))
                    if store.configuration.connections.contains(where: { $0.id == draft.id }) {
                        HakoDeleteButton(title: "删除此连接") { deleting = true }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .disabled(testing || store.busy)
        .onChange(of: draft) { _, _ in testResult = nil; error = nil }
        .hakoDeleteConfirmation(Text("删除此连接？"), isPresented: $deleting,
                                disabled: testing || store.busy) {
            do { try store.remove(draft.id); dismiss() } catch { self.error = error.localizedDescription }
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
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var results: [QinglongResource: QinglongPermissionResult] = [:]
    @State private var checking = false
    @State private var visible = false
    @State private var expanded: QinglongResource?
    @State private var checkedAt: Date?
    @State private var nonce = UUID()
    @State private var activeCheck: UUID?
    private struct CheckKey: Equatable {
        let revision: UUID
        let active: Bool
        let connectionID: String?
        let nonce: UUID
    }
    private var completed: Int { results.values.filter(\.completed).count }
    private var readable: Int { results.values.filter { $0 == .readable }.count }
    private var total: Int { QinglongResource.allCases.count }
    var body: some View {
        let key = CheckKey(revision: store.revision, active: visible && phase == .active, connectionID: store.connection?.id, nonce: nonce)
        Group {
            if embedded { content }
            else { NavigationStack { content } }
        }
        .onAppear { visible = true }.onDisappear { visible = false }
        .task(id: key) {
            guard key.connectionID != nil else {
                activeCheck = nil; checking = false; results = [:]; checkedAt = nil; expanded = nil
                return
            }
            guard key.active else { return }
            await check(revision: key.revision)
        }
    }
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("应用权限").font(.system(size: 28, weight: .bold)).tracking(-0.7)
                        Text(store.connection.map { $0.name + " · " + (checking ? "已检测 \(completed) / \(total) 个模块" : "\(readable) / \(total) 个模块可读取") } ?? "尚未配置面板")
                            .font(.caption).foregroundStyle(QinglongStyle.muted)
                    }
                    Spacer(minLength: 0)
                    Button { nonce = UUID() } label: {
                        Group { if checking { ProgressView() } else { Image(systemName: "arrow.clockwise").font(.system(size: 18)) } }
                            .frame(width: 44, height: 44).background(QinglongStyle.surface, in: Circle())
                    }.buttonStyle(.plain).disabled(checking || store.connection == nil).accessibilityLabel("重新检测应用权限")
                }
                HStack {
                    Text("模块读取权限"); Spacer(); Text(checking ? "检测中" : "\(total) 项")
                }.font(.system(size: 13, weight: .semibold)).foregroundStyle(QinglongStyle.muted).padding(.horizontal, 3)
                VStack(spacing: 0) {
                    ForEach(Array(QinglongResource.allCases.enumerated()), id: \.element.id) { index, resource in
                        if index > 0 { Rectangle().fill(QinglongStyle.line).frame(height: 1).padding(.leading, 55) }
                        permission(resource)
                    }
                }.qinglongCard(padding: 0, cornerRadius: 18)
                Text("仅验证列表读取，不代表拥有新增、编辑或运行权限。").font(.caption).foregroundStyle(QinglongStyle.muted).padding(.horizontal, 3)
                if let error = store.configurationError { QinglongNotice(text: error, error: true) }
                Text(checking ? "正在检测：\(QinglongResource.allCases.first { results[$0] == .checking }?.title ?? "")" : checkedAt.map { $0.formatted(date: .omitted, time: .standard) + " 检测" } ?? "尚未完成检测")
                    .font(.caption).foregroundStyle(QinglongStyle.muted).frame(maxWidth: .infinity)
            }.padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 26)
        }
        .background(QinglongStyle.background).foregroundStyle(QinglongStyle.text).tint(QinglongStyle.text)
        .navigationTitle("更多").navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(QinglongStyle.background, for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
        .toolbar { if !embedded { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } } }
    }
    private func permission(_ resource: QinglongResource) -> some View {
        let result = results[resource] ?? .pending
        return VStack(alignment: .leading, spacing: 0) {
            if let message = result.message {
                Button { expanded = expanded == resource ? nil : resource } label: { permissionRow(resource, result: result) }
                    .buttonStyle(.plain).accessibilityLabel("\(resource.title)，\(result.title)，查看原因")
                    .accessibilityValue(expanded == resource ? "已展开" : "已折叠")
                if expanded == resource {
                    Text(explanation(result, message: message))
                        .font(.caption).foregroundStyle(QinglongStyle.muted)
                        .padding(.leading, 52).padding(.trailing, 16).padding(.bottom, 16)
                }
            } else { permissionRow(resource, result: result).accessibilityElement(children: .combine) }
        }
    }
    private func explanation(_ result: QinglongPermissionResult, message: String) -> String {
        if case .failed = result { return "本次读取未成功，尚不能判断权限。\n" + message }
        return message
    }
    private func resultColor(_ result: QinglongPermissionResult) -> Color {
        switch result { case .readable: return QinglongStyle.success; case .denied: return QinglongStyle.failure; case .failed: return QinglongStyle.warning; default: return QinglongStyle.muted }
    }
    private func permissionRow(_ resource: QinglongResource, result: QinglongPermissionResult) -> some View {
        let color = resultColor(result)
        return HStack(spacing: 13) {
            Image(systemName: resource.symbol).font(.system(size: 19)).foregroundStyle(QinglongStyle.muted).frame(width: 23).accessibilityHidden(true)
            Text(resource.title).font(.subheadline.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 5) {
                if result == .checking { ProgressView().controlSize(.mini) }
                else { Image(systemName: result == .readable ? "checkmark" : result.message != nil ? "exclamationmark.circle" : "minus").accessibilityHidden(true) }
                Text(result.title)
            }.font(.caption).foregroundStyle(color)
            if result.message != nil { Image(systemName: "chevron.down").font(.system(size: 11)).foregroundStyle(QinglongStyle.muted).accessibilityHidden(true) }
        }.padding(.horizontal, 16).padding(.vertical, 15).frame(minHeight: 58).contentShape(Rectangle())
    }
    private func check(revision: UUID) async {
        let ticket = UUID()
        activeCheck = ticket; checking = true; results = [:]; expanded = nil; checkedAt = nil
        defer {
            if activeCheck == ticket {
                checking = false
                if Task.isCancelled {
                    for resource in QinglongResource.allCases where results[resource] == .checking { results[resource] = .pending }
                }
            }
        }
        do {
            let client = try store.client()
            for resource in QinglongResource.allCases {
                guard !Task.isCancelled, visible, revision == store.revision, activeCheck == ticket else { return }
                results[resource] = .checking
                do {
                    _ = try await client.list(resource)
                    guard !Task.isCancelled, visible, revision == store.revision, activeCheck == ticket else { return }
                    results[resource] = .readable
                } catch {
                    guard !Task.isCancelled, visible, revision == store.revision, activeCheck == ticket else { return }
                    results[resource] = QinglongPermissionResult(error: error)
                }
            }
            checkedAt = .now
        } catch {
            guard !Task.isCancelled, visible, revision == store.revision, activeCheck == ticket else { return }
            for resource in QinglongResource.allCases { results[resource] = QinglongPermissionResult(error: error) }
            checkedAt = .now
        }
    }
}
