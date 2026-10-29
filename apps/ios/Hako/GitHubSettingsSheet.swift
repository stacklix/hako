import SwiftUI

struct GitHubSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings = GitHubSettings.load()
    @State private var token = ""
    @State private var savedSettings: GitHubSettings?
    @State private var savedToken = ""
    @State private var message: String?
    private var hasChanges: Bool {
        guard let savedSettings else { return false }
        return settings != savedSettings || token != savedToken
    }

    var body: some View {
        SettingsSheet(title: "GitHub 配置", hasChanges: hasChanges,
                      saveEnabled: savedSettings != nil && hasChanges, onSave: save) {
            Form {
                Section("GitHub 仓库") {
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
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Personal Access Token").font(.subheadline).foregroundStyle(.secondary)
                        SecureField("输入 GitHub Token", text: $token)
                            .accessibilityLabel("Personal Access Token")
                    }
                }
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .disabled(savedSettings == nil)
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
            token = storedToken; savedToken = storedToken; savedSettings = settings
        } catch { message = error.localizedDescription }
    }
    private func save() {
        do {
            try settings.validate()
            try TokenStore.save(token.trimmingCharacters(in: .whitespacesAndNewlines))
            try settings.save()
            savedSettings = settings; savedToken = token
            dismiss()
        } catch { message = error.localizedDescription }
    }
}
