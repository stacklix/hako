import SwiftUI

struct ECSSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: ECSStore
    @State private var draft = ECSConnection()
    @State private var original = ECSConnection()
    @State private var loaded = false
    @State private var testing = false
    @State private var error: String?
    @State private var result: String?
    @State private var accessSettings = false

    var body: some View {
        SettingsSheet(title: "ECS 连接", hasChanges: loaded && draft != original, isBusy: testing,
                      saveEnabled: loaded && draft != original, onSave: save) {
            Form {
                Section("实例") {
                    field("连接名称", text: $draft.name, hint: "生产服务器")
                    field("地域 ID", text: $draft.region, hint: "cn-hangzhou")
                    field("实例 ID", text: $draft.instanceID, hint: "i-…")
                    field("Linux 用户名", text: $draft.username, hint: "root 或 ecs-user")
                }
                Section {
                    secret("AccessKey ID", text: $draft.accessKeyID)
                    secret("AccessKey Secret", text: $draft.accessKeySecret)
                    secret("STS Token（可选）", text: $draft.securityToken)
                } header: { Text("RAM 凭据") } footer: {
                    Text("凭据仅保存在本机钥匙串。使用 STS 时需同时填写临时 AccessKey 和 Token，到期后更新整组凭据。")
                }
                Section {
                    Button { Task { await test() } } label: {
                        HStack { Text("测试连接"); Spacer(); if testing { ProgressView() } }
                    }
                    if let result { Text(result).font(.footnote).foregroundStyle(.secondary) }
                    if let error { Text(error).font(.footnote).foregroundStyle(.orange) }
                } footer: {
                    Text("测试只查询实例信息。终端需启用阿里云会话管理；系统快照通过云助手读取，需要实例已有 Python 3，端口查询使用已有 ss 工具。Hako 不会自动安装软件。")
                }
                if let connection = store.connection {
                    Section("网站访问") {
                        Button("数据来源与关联域名") { accessSettings = true }
                    }
                    .sheet(isPresented: $accessSettings) { ECSAccessSettingsSheet(connection: connection) }
                }
            }
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .disabled(!loaded || testing)
            .task {
                do { draft = try ECSKeychain.load() ?? ECSConnection(); original = draft; loaded = true }
                catch { self.error = error.localizedDescription; loaded = true }
            }
            .onChange(of: draft) { _, _ in error = nil; result = nil }
        }
    }
    private func field(_ title: String, text: Binding<String>, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            TextField(hint, text: text).accessibilityLabel(title)
        }
    }
    private func secret(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            SecureField("输入\(title)", text: text).accessibilityLabel(title)
        }
    }
    private func save() {
        do { try store.configure(draft); original = draft; dismiss() }
        catch { self.error = error.localizedDescription }
    }
    private func test() async {
        testing = true; error = nil; result = nil
        defer { testing = false }
        do {
            let info = try await ECSClient(connection: draft).instance()
            result = "已找到实例：\(info.name)（\(info.status)）。"
        } catch { self.error = error.localizedDescription }
    }
}
