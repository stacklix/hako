import SwiftUI

private enum DeviceKeySheetRoute: String, Identifiable {
    case publicKey, reset
    var id: String { rawValue }
}

struct DeviceMonitorSettingsView: View {
    @ObservedObject private var client = ConsoleClient.shared
    @State private var url = ""
    @State private var username = ""
    @State private var keySheet: DeviceKeySheetRoute?
    @State private var confirmLogout = false
    @State private var loaded = false

    var body: some View {
        Form {
            Section("服务器连接") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("服务器地址").font(.subheadline).foregroundStyle(.secondary)
                    TextField("https://monitor.example.com", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("服务器地址")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("账号").font(.subheadline).foregroundStyle(.secondary)
                    TextField("输入账号", text: $username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("账号")
                }
                Button("保存服务器配置") {
                    Task { await client.saveServer(url, username: username) }
                }
            }.disabled(client.busy)

            Section("本机设备身份") {
                if !client.deviceId.isEmpty {
                    Text("设备 ID：\n" + client.deviceId)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                Button { openKeySheet(.publicKey) } label: {
                    Label("查看与导出公钥", systemImage: "key")
                }.disabled(client.resettingKey)
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                if !client.deviceId.isEmpty {
                    Button("重置密钥对", role: .destructive) { openKeySheet(.reset) }
                        .foregroundStyle(.red)
                        .disabled(client.busy)
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
        .sheet(item: $keySheet) { route in
            switch route {
            case .publicKey: DevicePublicKeySheet()
            case .reset: DeviceKeyResetSheet()
            }
        }
    }

    @MainActor private func openKeySheet(_ route: DeviceKeySheetRoute) {
        do {
            if route == .publicKey { _ = try client.publicKeyForExport() }
            keySheet = route
        } catch { client.message = error.localizedDescription }
    }
}
