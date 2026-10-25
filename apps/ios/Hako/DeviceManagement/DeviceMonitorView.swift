import SwiftUI
import UniformTypeIdentifiers

struct ConsolePublicKeyDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

struct DeviceMonitorView: View {
    @ObservedObject private var client = ConsoleClient.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmLogout = false
    @State private var exportKey = false

    var body: some View {
        List {
            if client.serverURL.isEmpty {
                Section {
                    ContentUnavailableView("尚未配置服务器", systemImage: "server.rack", description: Text("在主应用设置中填写服务器地址和账号。"))
                    NavigationLink("配置服务器") { DeviceServerSettingsView() }
                }
            } else if client.authenticated {
                Section("设备") {
                    if client.agents.isEmpty { Text("暂无登记的设备，请在服务端配置设备公钥。").foregroundStyle(.secondary) }
                    ForEach(client.agents) { agent in
                        NavigationLink { DeviceMetricsView(agent: agent) } label: {
                            HStack {
                                Image(systemName: "desktopcomputer")
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(agent.name)
                                    Text(agent.online ? "在线 · Windows" : "离线 · Windows").font(.caption).foregroundStyle(agent.online ? Color.green : Color.secondary)
                                }
                            }.padding(.vertical, 5)
                        }
                    }
                }
                Section {
                    Button("刷新设备列表") { Task { await client.fetchAgents() } }
                    NavigationLink("已登录设备") { ConsoleSessionsView() }
                    NavigationLink("扫码登录管理页") { ConsoleWebLoginView() }
                    Button("退出登录", role: .destructive) { confirmLogout = true }
                }.disabled(client.busy)
            } else if client.hasSavedSession {
                Section {
                    Text("已保存本机登录凭据，等待服务端验证。网络恢复后可继续使用。").foregroundStyle(.secondary)
                    Button("验证并继续") { Task { await client.restore() } }
                    Button("退出登录", role: .destructive) { confirmLogout = true }
                }.disabled(client.busy)
            } else {
                if client.logoutPending {
                    Section {
                        Text("本机已退出。仍保留仅用于撤销的加密凭据，等待服务端确认撤销。")
                        Button("重试撤销服务端会话") { Task { await client.restore() } }
                    }.disabled(client.busy)
                }
                Section("设备身份") {
                    LabeledContent("账号", value: client.username)
                    Text("首次使用时，请导出本机公钥并配置到服务端，然后登录。私钥保留在本机 Secure Enclave 中。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if !client.deviceId.isEmpty {
                        Text("设备 ID：" + client.deviceId).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    Button("导出公钥文件") { exportKey = true }.disabled(client.publicKeyPEM.isEmpty)
                    Button("使用本机密钥登录") { Task { await client.login() } }
                    NavigationLink("服务器设置") { DeviceServerSettingsView() }
                }.disabled(client.busy)
            }
            if client.busy { Section { ProgressView("正在处理…") } }
            if let message = client.message { Section { Text(message).font(.footnote).foregroundStyle(.secondary) } }
        }
        .navigationTitle("设备监控")
        .task { await client.restore() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await client.restore() } } }
        .confirmationDialog("退出设备监控登录？", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) { Task { await client.logout() } }
        }
        .fileExporter(isPresented: $exportKey, document: ConsolePublicKeyDocument(text: client.publicKeyPEM), contentType: .plainText, defaultFilename: "iphone.public.pem") { result in
            if case .failure(let error) = result { client.message = error.localizedDescription }
        }
    }
}

struct DeviceMetricsView: View {
    let agent: ConsoleAgent
    @ObservedObject private var client = ConsoleClient.shared
    var body: some View {
        List {
            Section {
                LabeledContent("设备", value: agent.name)
                Button("查询当前状态") { Task { await client.query(agent) } }.disabled(client.busy)
            }
            if let metrics = client.metrics[agent.id] {
                Section("CPU") {
                    LabeledContent("使用率", value: String(format: "%.1f%%", metrics.cpuUsagePercent))
                    ProgressView(value: metrics.cpuUsagePercent, total: 100)
                }
                Section("物理内存") {
                    LabeledContent("使用率", value: String(format: "%.1f%%", metrics.memoryUsagePercent))
                    ProgressView(value: metrics.memoryUsagePercent, total: 100)
                    LabeledContent("已用 / 总量", value: String(format: "%.1f / %.1f GiB", Double(metrics.memoryUsedBytes)/1_073_741_824, Double(metrics.memoryTotalBytes)/1_073_741_824))
                }
                Section {
                    Text("采样于 \(sampleTime(metrics.sampledAt))")
                    Text("采样窗口 \(metrics.sampleWindowMs) ms")
                }.font(.footnote).foregroundStyle(.secondary)
            } else if !client.busy {
                ContentUnavailableView("尚无本次采样结果", systemImage: "chart.bar", description: Text("查询会通过服务端转发到电脑，不持续上传历史数据。"))
            }
            if client.busy { ProgressView("正在查询设备…") }
            if let message = client.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
        }.navigationTitle("设备监控").task { await client.query(agent) }
    }
    private func sampleTime(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        return date?.formatted(date: .numeric, time: .standard) ?? value
    }
}

struct DeviceServerSettingsView: View {
    @ObservedObject private var client = ConsoleClient.shared
    @State private var url = ""
    @State private var username = ""
    @State private var exportKey = false
    var body: some View {
        Form {
            Section("设备管理服务器") {
                TextField("https://monitor.example.com", text: $url).keyboardType(.URL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("账号", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("保存并准备设备身份") { Task { await client.saveServer(url, username: username) } }.disabled(client.busy)
            }
            Section {
                Text("将本机公钥配置到服务端，即可通过设备签名登录。登录凭据与本机密钥绑定，持续有效，直到退出或被撤销。")
                    .font(.footnote).foregroundStyle(.secondary)
                if !client.publicKeyPEM.isEmpty {
                    Button("导出本机公钥") { exportKey = true }
                    Text("设备 ID：" + client.deviceId).font(.caption.monospaced()).textSelection(.enabled)
                }
                NavigationLink("打开设备监控") { DeviceMonitorView() }
            }
            if client.busy { ProgressView("正在检查…") }
            if let message = client.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
        }.navigationTitle("服务器连接").onAppear { url = client.serverURL; username = client.username }
        .task { await client.restore() }
        .fileExporter(isPresented: $exportKey, document: ConsolePublicKeyDocument(text: client.publicKeyPEM), contentType: .plainText, defaultFilename: "iphone.public.pem") { result in
            if case .failure(let error) = result { client.message = error.localizedDescription }
        }
    }
}

struct ConsoleSessionsView: View {
    @ObservedObject private var client = ConsoleClient.shared
    var body: some View {
        List {
            ForEach(client.remoteSessions) { session in
                VStack(alignment: .leading, spacing: 8) {
                    Text(session.current ? "当前 iPhone" : "管理客户端")
                    Text(session.deviceId).font(.caption.monospaced()).foregroundStyle(.secondary)
                    if !session.current {
                        Button("撤销此设备的登录", role: .destructive) { Task { await client.revoke(session) } }.disabled(client.busy)
                    }
                }.padding(.vertical, 5)
            }
            if client.busy { ProgressView() }
            if let message = client.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
        }.navigationTitle("已登录设备").task { await client.fetchSessions() }
    }
}
