import SwiftUI

struct ConsoleApplicationEditorView: View {
    @ObservedObject var client: ConsoleApplicationsClient
    let application: ConsoleApplication?
    let onCreated: (ConsoleApplicationCredential) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ConsoleApplicationDraft
    @State private var errorMessage: String?
    @State private var confirmingSave = false
    @State private var submitting = false
    private let initial: ConsoleApplicationDraft
    private let context: String
    init(client: ConsoleApplicationsClient, application: ConsoleApplication?, onCreated: @escaping (ConsoleApplicationCredential) -> Void) {
        self.client = client; self.application = application; self.onCreated = onCreated
        let initial = ConsoleApplicationDraft(application: application)
        self.initial = initial; self._draft = State(initialValue: initial); self.context = client.context
    }
    private var canSave: Bool { client.authenticated && context == client.context && !client.busy && draft.hasRequiredInput && (application == nil || (draft != initial && (draft.oidcEnabled || application?.oidc != nil))) }
    var body: some View {
        SettingsSheet(title: application == nil ? "登记应用" : "OIDC 配置", hasChanges: draft != initial,
                      isBusy: submitting, saveEnabled: canSave, onSave: requestSave) {
            Form {
                Section {
                    if application == nil {
                        field("应用名称", placeholder: "例如：Headplane", text: $draft.name)
                        field("登记来源", placeholder: "https://app.example.com", text: $draft.origin, url: true)
                    } else {
                        HakoLabeledValue(label: "应用名称", value: draft.name)
                        HakoLabeledValue(label: "登记来源", value: draft.origin)
                    }
                } header: { Text("应用信息") } footer: {
                    Text("手机确认授权时会展示应用名称与登记来源。来源为根地址，支持 HTTPS 或局域网 HTTP。")
                }
                Section("登录方式") {
                    VStack(alignment: .leading, spacing: 5) {
                        LabeledContent("扫码登录", value: "支持")
                        Text("登记后即可使用 Hako 自定义扫码登录").font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle(isOn: $draft.oidcEnabled) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("启用 OIDC 登录")
                            Text("供支持 OpenID Connect 的应用使用").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if draft.oidcEnabled {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("精确回调地址").font(.subheadline).foregroundStyle(.secondary)
                            TextEditor(text: $draft.redirects).frame(minHeight: 90)
                                .font(.footnote.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled()
                                .accessibilityLabel("精确回调地址，每行一个")
                        }
                    } header: { Text("回调地址") } footer: {
                        Text("每行一个完整 HTTPS 地址，不使用通配符。必须与应用的回调地址完全一致。")
                    }
                    Section {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("稳定账号标识")
                                Text("openid · 必选").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "checkmark").accessibilityLabel("已选，必选")
                        }
                        Toggle(isOn: $draft.profile) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("账号名称")
                                Text("profile · 返回当前账号名称").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } header: { Text("身份信息") } footer: { Text("不提供邮箱，也不授予 Hako 管理权限。") }
                    Section("认证选项") {
                        Toggle(isOn: $draft.requirePKCE) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("要求 PKCE S256")
                                Text("推荐开启，客户端必须同步启用 PKCE").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("客户端认证方式").font(.subheadline).foregroundStyle(.secondary)
                            Picker("客户端认证方式", selection: $draft.authMethod) {
                                Text("client_secret_basic（推荐）").tag("client_secret_basic")
                                Text("client_secret_post").tag("client_secret_post")
                            }.labelsHidden().pickerStyle(.menu).accessibilityLabel("客户端认证方式")
                        }
                    }
                }
                if application != nil {
                    Section {
                        Text("保存配置会使该应用已有的待授权请求、授权码和 Hako 访问授权失效。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if submitting { Section { ProgressView("正在保存应用…") } }
                if let errorMessage { Section { Text(errorMessage).font(.footnote).foregroundStyle(.red) } }
            }.disabled(submitting || !client.authenticated || context != client.context)
            .alert("保存 OIDC 配置？", isPresented: $confirmingSave) {
                Button("保存配置", role: .destructive) { Task { await save() } }
                Button("取消", role: .cancel) { }
            } message: { Text("该应用已有的待授权请求、授权码和 Hako 访问授权将失效。第三方应用自己的登录会话由它管理。") }
        }
        .onChange(of: client.context) { _, _ in dismiss() }
    }
    private func field(_ label: String, placeholder: String, text: Binding<String>, url: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            TextField(placeholder, text: text).textInputAutocapitalization(.never).autocorrectionDisabled()
                .keyboardType(url ? .URL : .default).accessibilityLabel(label)
        }
    }
    private func requestSave() {
        errorMessage = nil
        do {
            if application == nil { _ = try draft.creationBody(); Task { await save() } }
            else { _ = try draft.updateBody(); confirmingSave = true }
        } catch { errorMessage = error.localizedDescription }
    }
    @MainActor private func save() async {
        guard canSave, !submitting else { return }
        submitting = true; errorMessage = nil
        defer { submitting = false }
        do {
            if let application { try await client.updateOIDC(application, draft: draft) }
            else { onCreated(try await client.create(draft)) }
            dismiss()
        } catch is CancellationError { }
        catch { errorMessage = error.localizedDescription }
    }
}
