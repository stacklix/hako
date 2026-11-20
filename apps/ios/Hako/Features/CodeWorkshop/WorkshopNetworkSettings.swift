import SwiftUI

struct WorkshopComputerSettingsRow: View {
    @ObservedObject var store: WorkshopStore
    let agent: WorkshopAgent
    let namespace: String
    @State private var expanded = false
    @State private var editing = false
    @State private var original: LocalNetworkEndpoint?
    private var status: String {
        let state = agent.online ? agent.supported ? "在线" : "需要更新 Agent" : "离线"
        return original.map { state + " · " + $0.address } ?? state
    }

    init(store: WorkshopStore, agent: WorkshopAgent, namespace: String) {
        self.store = store; self.agent = agent; self.namespace = namespace
        let saved = WorkshopNetworkConfiguration.load(agentID: agent.id, namespace: namespace)
        _original = State(initialValue: saved)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Button { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.subheadline).foregroundStyle(.secondary).frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel((expanded ? "收起" : "展开") + agent.name + "的局域网配置")
                .accessibilityValue(expanded ? "已展开" : "已折叠")
                Button { Task { await store.selectAgent(agent.id) } } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(agent.name).foregroundStyle(.primary)
                            Text(status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        if agent.id == store.selectedAgentID { Image(systemName: "checkmark") }
                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.borderless).disabled(store.loading)
                    .accessibilityLabel("选择执行电脑" + agent.name)
                    .accessibilityAddTraits(agent.id == store.selectedAgentID ? .isSelected : [])
            }
            if expanded {
                VStack(alignment: .leading, spacing: 16) {
                    Divider()
                    HStack {
                        Spacer()
                        Button("编辑") { editing = true }
                            .font(.subheadline).foregroundStyle(.secondary)
                            .frame(minWidth: 44, minHeight: 44).buttonStyle(.borderless)
                            .accessibilityLabel("编辑" + agent.name + "的局域网地址")
                    }
                    LabeledContent("局域网 IP", value: original?.ip ?? "未配置")
                    LabeledContent("端口", value: original.map { String($0.port) } ?? "未配置")
                }.padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
        .sheet(isPresented: $editing) {
            WorkshopComputerAddressSheet(store: store, agent: agent, namespace: namespace, original: original) {
                original = $0
            }
        }
    }
}

private struct WorkshopComputerAddressSheet: View {
    @ObservedObject var store: WorkshopStore
    let agent: WorkshopAgent
    let namespace: String
    let original: LocalNetworkEndpoint?
    let onSaved: (LocalNetworkEndpoint?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var ip: String
    @State private var port: String
    @State private var error: String?
    @State private var confirmingDelete = false
    @State private var testTask: Task<Void, Never>?
    @State private var testID = UUID()
    @State private var testing = false
    @State private var testResult: String?
    @State private var testFailed = false

    private var endpoint: LocalNetworkEndpoint? {
        Int(port.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { LocalNetworkEndpoint(ip: ip, port: $0) }
    }
    private var changed: Bool {
        ip != (original?.ip ?? "") || port != (original.map { String($0.port) } ?? "")
    }

    init(store: WorkshopStore, agent: WorkshopAgent, namespace: String, original: LocalNetworkEndpoint?,
         onSaved: @escaping (LocalNetworkEndpoint?) -> Void) {
        self.store = store; self.agent = agent; self.namespace = namespace
        self.original = original; self.onSaved = onSaved
        _ip = State(initialValue: original?.ip ?? "")
        _port = State(initialValue: original.map { String($0.port) } ?? "")
    }

    var body: some View {
        SettingsSheet(title: "局域网地址", hasChanges: changed,
                      saveEnabled: endpoint != nil && namespace == store.networkNamespace,
                      onSave: { save(endpoint) }, saveAccessibilityLabel: "确认局域网地址",
                      cancelTitle: "取消", saveTitle: "确认") {
            Form {
                Section {
                    Text(agent.name)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("局域网 IP").font(.subheadline).foregroundStyle(.secondary)
                        TextField("例如 192.168.0.10", text: $ip).keyboardType(.URL)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityLabel("局域网 IP")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("端口").font(.subheadline).foregroundStyle(.secondary)
                        TextField("Agent 的直连端口", text: $port).keyboardType(.numberPad)
                            .accessibilityLabel("直连端口")
                    }
                } footer: {
                    Text("仅在主应用识别为局域网时使用此电脑的地址。测试连接使用当前填写的地址，确认后保存。")
                }
                if let error {
                    Section { Text(error).font(.footnote).foregroundStyle(.red) }
                }
                Section {
                    HStack(spacing: 12) {
                        if original != nil {
                            Button("删除", role: .destructive) { confirmingDelete = true }
                                .buttonStyle(HakoActionButtonStyle(destructive: true))
                                .accessibilityLabel("删除局域网地址")
                        }
                        Button(action: testConnection) {
                            HStack(spacing: 6) {
                                if testing { ProgressView() }
                                Text(testing ? "测试中…" : "测试连接")
                            }.frame(maxWidth: .infinity)
                        }
                        .buttonStyle(HakoActionButtonStyle(primary: false))
                        .disabled(testing || endpoint == nil || namespace != store.networkNamespace)
                    }
                    .listRowSeparator(.hidden)
                    if let testResult {
                        Text(testResult).font(.footnote)
                            .foregroundStyle(testFailed ? Color.red : Color.secondary)
                    }
                }.listRowBackground(Color.clear)
            }
        }
        .hakoDeleteConfirmation(Text("删除局域网地址？"), isPresented: $confirmingDelete,
            message: Text("删除后，仍可通过服务器连接此电脑。")) { save(nil) }
        .onChange(of: ip) { _, _ in invalidateTest() }
        .onChange(of: port) { _, _ in invalidateTest() }
        .onChange(of: store.networkNamespace) { _, _ in invalidateTest(); dismiss() }
        .onDisappear { invalidateTest() }
    }

    private func invalidateTest() {
        testID = UUID(); testTask?.cancel(); testTask = nil
        testing = false; testResult = nil; error = nil
    }

    private func testConnection() {
        guard let endpoint, namespace == store.networkNamespace else { return }
        invalidateTest()
        let id = testID
        testing = true
        testTask = Task { @MainActor in
            do {
                await LocalNetworkService.shared.refresh()
                try Task.checkCancellation()
                guard LocalNetworkService.shared.isLocal else {
                    throw ConnectionTestError.notLocal
                }
                let (connection, hello) = try await WorkshopLocalSocket.open(endpoint, path: "/workshop/v1")
                defer { connection.closeWorkshop() }
                try Task.checkCancellation()
                try WorkshopNetworkConfiguration.requireComputer(hello, agentID: agent.id)
                guard id == testID, namespace == store.networkNamespace else { return }
                testResult = "连接成功 · 电脑身份匹配"; testFailed = false
            } catch {
                guard !Task.isCancelled, id == testID, namespace == store.networkNamespace else { return }
                testResult = "连接失败：" + WorkshopNetworkConfiguration.connectionFailureMessage(error); testFailed = true
            }
            guard id == testID else { return }
            testing = false; testTask = nil
        }
    }

    private func save(_ value: LocalNetworkEndpoint?) {
        guard namespace == store.networkNamespace else { dismiss(); return }
        do {
            try WorkshopNetworkConfiguration.save(value, agentID: agent.id, namespace: namespace)
            invalidateTest(); onSaved(value); dismiss()
            Task { await store.prepareNetwork(); await store.refresh() }
        } catch { self.error = error.localizedDescription }
    }

    private enum ConnectionTestError: LocalizedError {
        case notLocal
        var errorDescription: String? { "当前网络未被识别为局域网，请检查主应用的局域网配置。" }
    }
}
