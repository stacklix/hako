import SwiftUI

struct ArcaneSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: ArcaneStore
    @State private var connection = ArcaneConnection()
    @State private var original: ArcaneConnection?
    @State private var loaded = false
    @State private var testing = false
    @State private var testResult: String?
    @State private var message: String?
    private var hasChanges: Bool { loaded && connection != original }

    var body: some View {
        SettingsSheet(title: "Arcane 连接", hasChanges: hasChanges, isBusy: testing,
                      saveEnabled: loaded && hasChanges && store.pending == nil, onSave: save) {
            Form {
                Section("连接信息") {
                    TextField("连接名称", text: $connection.name)
                    TextField("https://arcane.example.com", text: $connection.address)
                        .keyboardType(.URL).accessibilityLabel("Arcane 服务地址")
                    SecureField("API Key", text: $connection.apiKey)
                        .accessibilityLabel("Arcane API Key")
                }
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .disabled(!loaded || testing)
                Section {
                    Toggle("允许不加密的 HTTP 连接", isOn: $connection.allowHTTP)
                } footer: {
                    Text("HTTPS 会验证服务端证书。HTTP 仅用于可信网络，API Key 将明文传输。")
                }.disabled(!loaded || testing)
                Section {
                    Button {
                        Task { await test() }
                    } label: {
                        HStack { Text("测试连接"); Spacer(); if testing { ProgressView() } }
                    }.disabled(!loaded || testing)
                    if let testResult { Text(testResult).font(.footnote).foregroundStyle(.secondary) }
                    if let message { Text(message).font(.footnote).foregroundStyle(.red) }
                    if !loaded { Button("重试读取配置", action: load) }
                } footer: {
                    Text("API Key 仅保存在本机系统钥匙串，不上传 Hako 服务端。测试连接只验证可访问的环境；只有点击右上角勾号才会保存。")
                }
                if store.pending != nil {
                    Section { Text("当前有尚未确认的容器操作，请先回到容器管理核对结果，再修改连接。") }
                }
            }
            .task { if !loaded { load() } }
            .onChange(of: connection) { _, _ in testResult = nil; message = nil }
        }
    }

    private func load() {
        do {
            let value = try ArcaneKeychain.load() ?? ArcaneConnection()
            connection = value; original = value; loaded = true; message = nil
        } catch { message = error.localizedDescription }
    }

    private func save() {
        do { try store.configure(connection); original = connection; dismiss() }
        catch { message = error.localizedDescription }
    }

    private func test() async {
        testing = true; message = nil; testResult = nil
        defer { testing = false }
        do {
            let environments = try await ArcaneClient(connection: connection).environments()
            testResult = environments.isEmpty ? "连接成功，但此 API Key 没有可访问的环境。" : "连接成功，可访问 \(environments.count) 个环境。"
        } catch { message = error.localizedDescription }
    }
}
