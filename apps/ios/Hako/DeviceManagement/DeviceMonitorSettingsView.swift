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

struct DeviceMonitorSettingsView: View {
    @ObservedObject private var client = ConsoleClient.shared
    @State private var url = ""
    @State private var username = ""
    @State private var exportKey = false
    @State private var confirmLogout = false
    @State private var loaded = false

    var body: some View {
        Form {
            Section("服务器连接") {
                TextField("https://monitor.example.com", text: $url).keyboardType(.URL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("账号", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("保存并准备设备身份") { Task { await client.saveServer(url, username: username) } }
            }.disabled(client.busy)

            Section("本机设备身份") {
                Text("将本机公钥手工配置到服务端，即可通过设备签名登录。私钥保留在本机 Secure Enclave 中。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button { exportKey = true } label: {
                    Label("导出公钥文件", systemImage: "square.and.arrow.up")
                }.disabled(client.busy || client.publicKeyPEM.isEmpty)
                if client.publicKeyPEM.isEmpty {
                    Text("先点击上方「保存并准备设备身份」生成本机密钥，再导出公钥，无需先登录服务器。")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("设备 ID：" + client.deviceId).font(.caption.monospaced()).textSelection(.enabled)
                }
            }

            if !client.serverURL.isEmpty {
                Section("登录管理") {
                    if client.authenticated {
                        LabeledContent("状态", value: "已登录")
                        NavigationLink("已登录设备") { ConsoleSessionsView() }
                        Button("退出登录", role: .destructive) { confirmLogout = true }
                    } else if client.hasSavedSession {
                        Text("已保存本机登录凭据，等待服务端验证。网络恢复后可继续使用。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("验证并继续") { Task { await client.restore() } }
                        Button("退出登录", role: .destructive) { confirmLogout = true }
                    } else if client.logoutPending {
                        Text("本机已退出，等待联网后撤销服务端会话。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("重试撤销服务端会话") { Task { await client.restore() } }
                    } else {
                        Button("使用本机密钥登录") { Task { await client.login() } }
                            .disabled(client.publicKeyPEM.isEmpty)
                    }
                }.disabled(client.busy)
            }
            if client.busy { ProgressView("正在处理…") }
            if let message = client.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
        }
        .navigationTitle("设备监控设置")
        .task {
            guard !loaded else { return }
            loaded = true
            url = client.serverURL; username = client.username
            await client.restore()
        }
        .confirmationDialog("退出设备监控登录？", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) { Task { await client.logout() } }
        }
        .fileExporter(isPresented: $exportKey, document: ConsolePublicKeyDocument(text: client.publicKeyPEM), contentType: .plainText, defaultFilename: "iphone.public.pem") { result in
            if case .failure(let error) = result { client.message = error.localizedDescription }
        }
    }
}
