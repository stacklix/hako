import SwiftUI
import UIKit

private struct ApplicationEditorRoute: Identifiable {
    let id = UUID()
    let application: ConsoleApplication?
}

struct ConsoleApplicationsView: View {
    @StateObject private var client = ConsoleApplicationsClient()
    @State private var editor: ApplicationEditorRoute?
    @State private var credential: ConsoleApplicationCredential?
    @State private var pendingCredential: ConsoleApplicationCredential?
    @State private var showingServer = false
    @State private var pendingDetailID: String?
    @State private var createdDetailID: String?
    @State private var showingCreatedDetail = false
    @State private var errorMessage: String?

    var body: some View {
        SettingsSheet(title: "第三方应用", isBusy: client.busy) {
            List {
                Section {
                    Label(client.serverURL.isEmpty ? "尚未配置 Hako 服务器" : client.serverURL, systemImage: "server.rack")
                        .font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if !client.authenticated {
                    Section {
                        ContentUnavailableView {
                            Label("先登录 Hako 服务器", systemImage: "lock.shield")
                        } description: {
                            Text("使用已登记的本机设备身份登录，即可登记和管理第三方应用。")
                        } actions: {
                            Button("服务器与登录") { showingServer = true }
                        }
                    }
                } else if client.applications.isEmpty && client.loaded {
                    Section {
                        ContentUnavailableView {
                            Label("还没有第三方应用", systemImage: "square.stack.3d.up")
                        } description: {
                            Text("登记应用，让它通过扫码或 OIDC 使用 Hako 登录。")
                        } actions: {
                            Button("登记应用") { editor = ApplicationEditorRoute(application: nil) }
                                .disabled(client.busy)
                        }
                    }
                } else {
                    Section {
                        ForEach(client.applications) { application in
                            NavigationLink(value: application.id) {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(application.name)
                                        Text("\(application.loginMethods) · \(application.origin)")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                    Text(application.enabled ? "已启用" : "已停用")
                                        .font(.caption).foregroundStyle(application.enabled ? .green : .secondary)
                                }.padding(.vertical, 3)
                            }
                        }
                    } header: { Text("已登记的应用") } footer: {
                        Text("应用登记在当前服务器，与网页管理端共用。")
                    }
                }
                if client.busy { Section { ProgressView("正在读取或更新应用…") } }
                if let errorMessage {
                    Section { Text(errorMessage).font(.footnote).foregroundStyle(.red) }
                }
            }
            .navigationDestination(for: String.self) { id in
                detail(id)
            }
            .navigationDestination(isPresented: $showingCreatedDetail) {
                if let id = createdDetailID { detail(id) }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if client.authenticated {
                        Button { editor = ApplicationEditorRoute(application: nil) } label: { Image(systemName: "plus") }
                            .accessibilityLabel("登记第三方应用").disabled(client.busy)
                    }
                }
            }
            .refreshable { await refresh() }
        }
        .sheet(item: $editor, onDismiss: {
            if let pending = pendingCredential, pending.context == client.context, client.authenticated { credential = pending }
            pendingCredential = nil
        }) { route in
            ConsoleApplicationEditorView(client: client, application: route.application) { result in
                pendingCredential = result
                pendingDetailID = result.application.id
            }
        }
        .sheet(item: $credential, onDismiss: {
            if let id = pendingDetailID, client.authenticated {
                createdDetailID = id; showingCreatedDetail = true
            }
            pendingDetailID = nil
        }) { value in ConsoleApplicationSecretView(client: client, credential: value) }
        .sheet(isPresented: $showingServer) { ServerSettingsView() }
        .task(id: client.context) {
            pendingDetailID = nil; showingCreatedDetail = false; createdDetailID = nil
            credential = nil; pendingCredential = nil; editor = nil; errorMessage = nil
            await client.restore()
            guard !Task.isCancelled, client.authenticated else { return }
            await refresh()
        }
    }
    private func detail(_ id: String) -> some View {
        ConsoleApplicationDetailView(client: client, applicationID: id,
            edit: { editor = ApplicationEditorRoute(application: $0) },
            showCredential: { credential = $0 })
    }
    @MainActor private func refresh() async {
        errorMessage = nil
        do { try await client.refresh() }
        catch is CancellationError { }
        catch { errorMessage = error.localizedDescription }
    }
}

private struct ConsoleApplicationDetailView: View {
    @ObservedObject var client: ConsoleApplicationsClient
    let applicationID: String
    let edit: (ConsoleApplication) -> Void
    let showCredential: (ConsoleApplicationCredential) -> Void
    @State private var errorMessage: String?
    @State private var confirmation: Action?
    @State private var copied = false
    private enum Action { case disable, rotate }
    private var application: ConsoleApplication? { client.applications.first { $0.id == applicationID } }
    var body: some View {
        Form {
            if let application {
                Section("应用信息") {
                    ApplicationValue(label: "登记来源", value: application.origin)
                    ApplicationValue(label: "Client ID", value: application.id, monospaced: true)
                    Toggle("启用应用", isOn: Binding(get: { application.enabled }, set: { value in
                        if value { Task { await setEnabled(application, true) } }
                        else { confirmation = .disable }
                    })).disabled(client.busy)
                }
                Section("登录方式") {
                    LabeledContent("扫码登录", value: "支持")
                    Button { edit(application) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("OIDC 登录")
                                Text(application.usesOIDC ? "已启用 · \(application.oidc?.scopes.joined(separator: " ") ?? "")" : "未启用")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
                        }.foregroundStyle(.primary)
                    }.disabled(client.busy)
                }
                if let oidc = application.oidc, oidc.enabled {
                    Section("OIDC 接入信息") {
                        ApplicationValue(label: "Issuer", value: client.serverURL, monospaced: true)
                        ApplicationValue(label: "精确回调地址", value: oidc.redirectURIs.joined(separator: "\n"), monospaced: true)
                        ApplicationValue(label: "允许的 scopes", value: oidc.scopes.joined(separator: " "), monospaced: true)
                        ApplicationValue(label: "客户端认证方式", value: oidc.authMethod, monospaced: true)
                        LabeledContent("PKCE S256", value: oidc.requirePKCE ? "要求使用" : "可选")
                    }
                }
                Section {
                    Button {
                        UIPasteboard.general.string = application.configuration(issuer: client.serverURL)
                        copied = true
                    } label: { Label(copied ? "已复制接入信息" : "复制接入信息", systemImage: copied ? "checkmark" : "doc.on.doc") }
                    Button { confirmation = .rotate } label: { Label("轮换 Client Secret", systemImage: "key.horizontal") }
                        .disabled(client.busy)
                } header: { Text("接入凭据") } footer: {
                    Text("Client Secret 仅在创建或轮换时显示，无法再次查看。")
                }
                if client.busy { Section { ProgressView("正在更新应用…") } }
                if let errorMessage { Section { Text(errorMessage).font(.footnote).foregroundStyle(.red) } }
            } else {
                ContentUnavailableView("应用暂不可用", systemImage: "square.stack.3d.up", description: Text("请返回并刷新列表，或验证当前 Hako 登录。"))
            }
        }
        .navigationTitle(application?.name ?? "第三方应用").navigationBarTitleDisplayMode(.inline)
        .alert(confirmation == .rotate ? "轮换 Client Secret？" : "停用应用？", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })) {
            let action = confirmation
            Button(action == .rotate ? "轮换 Secret" : "停用应用", role: .destructive) {
                guard let application else { return }
                Task {
                    errorMessage = nil
                    do {
                        if action == .rotate { showCredential(try await client.rotate(application)) }
                        else { try await client.setEnabled(application, enabled: false) }
                    } catch is CancellationError { }
                    catch { errorMessage = error.localizedDescription }
                }
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text(confirmation == .rotate ? "旧 Secret 会立即失效，已有的待授权请求、授权码和 Hako 访问授权也会失效。请同步更新应用后端配置。" : "该应用无法再发起新的 Hako 登录，已有的待授权请求、授权码和 Hako 访问授权将失效。第三方应用自己的登录会话由它管理。")
        }
        .onChange(of: client.context) { _, _ in errorMessage = nil; confirmation = nil; copied = false }
    }
    @MainActor private func setEnabled(_ application: ConsoleApplication, _ enabled: Bool) async {
        errorMessage = nil
        do { try await client.setEnabled(application, enabled: enabled) }
        catch is CancellationError { }
        catch { errorMessage = error.localizedDescription }
    }
}

struct ApplicationValue: View {
    let label: String
    let value: String
    var monospaced = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(monospaced ? .footnote.monospaced() : .body).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
