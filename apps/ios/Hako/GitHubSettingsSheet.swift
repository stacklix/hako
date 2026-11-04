import SwiftUI

struct GitHubSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings = GitHubSettings.load()
    @State private var privateSettings = GitHubSettings.loadPrivate()
    @State private var savedPrivateSettings = GitHubSettings.loadPrivate()
    @State private var token = ""
    @State private var savedSettings: GitHubSettings?
    @State private var savedToken = ""
    @State private var message: String?
    private var hasChanges: Bool {
        guard let savedSettings else { return false }
        return settings != savedSettings || privateSettings != savedPrivateSettings || token != savedToken
    }

    var body: some View {
        SettingsSheet(title: "GitHub 配置", hasChanges: hasChanges,
                      saveEnabled: savedSettings != nil && hasChanges, onSave: save) {
            Form {
                Section("公开仓库 · 运动与使用记录") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("仓库地址").font(.subheadline).foregroundStyle(.secondary)
                        TextField("https://github.com/username/repository", text: $settings.repositoryURL)
                            .keyboardType(.URL)
                            .accessibilityLabel("仓库地址")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("分支").font(.subheadline).foregroundStyle(.secondary)
                        TextField("master", text: $settings.branch)
                            .accessibilityLabel("分支")
                    }
                }
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .disabled(savedSettings == nil)
                Section("私有仓库 · 加密资产") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("私有仓库地址").font(.subheadline).foregroundStyle(.secondary)
                        TextField("https://github.com/username/private-data", text: $privateSettings.repositoryURL)
                            .keyboardType(.URL).accessibilityLabel("私有仓库地址")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("私有仓库分支").font(.subheadline).foregroundStyle(.secondary)
                        TextField("master", text: $privateSettings.branch).accessibilityLabel("私有仓库分支")
                    }
                    Text("沿用上述 Token，请授予两个仓库的读写权限。加密资产同步前会确认目标为私有仓库；不会回退到公开库。")
                        .font(.caption).foregroundStyle(.secondary)
                }.textInputAutocapitalization(.never).autocorrectionDisabled().disabled(savedSettings == nil)
                Section("共享认证 · 两个仓库共用") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Personal Access Token").font(.subheadline).foregroundStyle(.secondary)
                        SecureField("输入 GitHub Token", text: $token)
                            .accessibilityLabel("两个仓库共享的 Personal Access Token")
                    }
                }.textInputAutocapitalization(.never).autocorrectionDisabled().disabled(savedSettings == nil)
                if savedSettings == nil {
                    Button("重试读取配置") { load() }
                }
            }
            .task { if savedSettings == nil { load() } }
            .alert("无法保存或读取 GitHub 配置", isPresented: Binding(
                get: { message != nil }, set: { if !$0 { message = nil } }
            )) { Button("好") { message = nil } } message: { Text(message ?? "") }
        }
    }

    private func load() {
        do {
            let storedToken = try TokenStore.read()
            settings = GitHubSettings.load()
            privateSettings = .loadPrivate(); savedPrivateSettings = privateSettings
            token = storedToken; savedToken = storedToken; savedSettings = settings
        } catch { message = error.localizedDescription }
    }
    private func save() {
        do {
            try settings.validate()
            if !privateSettings.repositoryURL.isEmpty { try privateSettings.validate() }
            try TokenStore.save(token.trimmingCharacters(in: .whitespacesAndNewlines))
            try settings.save()
            try privateSettings.savePrivate()
            savedSettings = settings; savedToken = token
            dismiss()
        } catch { message = error.localizedDescription }
    }
}
