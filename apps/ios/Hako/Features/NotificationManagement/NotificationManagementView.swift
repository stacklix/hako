import SwiftUI

struct NotificationManagementView: View {
    private struct Editor: Identifiable {
        let id = UUID()
        let webhook: HakoWebhook?
    }
    private enum Confirmation {
        case disable(HakoWebhook), rotate(HakoWebhook), delete(HakoWebhook)
        var title: String {
            switch self {
            case .disable: "停用 Webhook？"
            case .rotate: "重置 Token？"
            case .delete: "删除 Webhook？"
            }
        }
        var message: String {
            switch self {
            case .disable: "停用后，外部应用无法通过此地址发送通知。随时可以重新启用。"
            case .rotate: "旧地址将立即失效，请保存新地址并更新外部应用的配置。"
            case .delete: "接口地址将立即失效，相关调用记录也会删除。此操作无法撤销。"
            }
        }
        var buttonTitle: String {
            switch self {
            case .disable: "停用"
            case .rotate: "重置并生成新地址"
            case .delete: "删除 Webhook"
            }
        }
    }

    @StateObject private var store = NotificationManagementStore()
    @State private var editor: Editor?
    @State private var showingServer = false
    @State private var confirmation: Confirmation?
    @State private var secret: HakoWebhookSecret?
    @State private var pendingSecret: HakoWebhookSecret?
    @State private var error: String?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if store.authenticated { content }
            else {
                ContentUnavailableView {
                    Label("登录 Sora 后管理 Webhook", systemImage: "link")
                } description: {
                    Text("使用 Hako 当前的服务器登录会话。")
                } actions: {
                    Button("服务器与登录") { showingServer = true }
                        .buttonStyle(HakoActionButtonStyle()).padding(.horizontal, 28)
                }
            }
        }
        .navigationTitle("Webhook 管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editor = Editor(webhook: nil) } label: { Image(systemName: "plus") }
                    .accessibilityLabel("创建 Webhook")
                    .disabled(!store.authenticated || store.working || !store.loaded)
            }
        }
        .sheet(isPresented: $showingServer) { ServerSettingsView() }
        .sheet(item: $editor, onDismiss: {
            secret = pendingSecret; pendingSecret = nil
        }) { selection in
            HakoWebhookEditor(store: store, webhook: selection.webhook) { hook, address in
                store.update(hook)
                if let address, scenePhase == .active {
                    pendingSecret = HakoWebhookSecret(name: hook.name, address: address)
                }
                editor = nil
            }
        }
        .sheet(item: $secret) { HakoWebhookSecretView(secret: $0) }
        .confirmationDialog(confirmation?.title ?? "", isPresented: Binding(
            get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }
        ), titleVisibility: .visible) {
            if let confirmation {
                Button(confirmation.buttonTitle, role: .destructive) {
                    Task { await perform(confirmation) }
                }
            }
        } message: { Text(confirmation?.message ?? "") }
        .task(id: store.context) { await store.prepare() }
        .onChange(of: store.context) { _, _ in
            editor = nil; secret = nil; pendingSecret = nil; confirmation = nil; error = nil
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { secret = nil; pendingSecret = nil }
        }
    }

    private var content: some View {
        List {
            if let error = error ?? store.error {
                Section {
                    Text(error).foregroundStyle(.red).font(.subheadline).notificationRow()
                    Button("刷新列表") { Task { self.error = nil; await store.refresh() } }
                        .disabled(store.loading).notificationRow()
                }
            }
            Section {
                if store.loading && !store.loaded {
                    HStack { Spacer(); ProgressView("正在加载…"); Spacer() }.notificationRow()
                } else if !store.loaded && store.error != nil {
                    ContentUnavailableView("无法加载 Webhook", systemImage: "wifi.exclamationmark").notificationRow()
                } else if store.hooks.isEmpty {
                    ContentUnavailableView("还没有 Webhook", systemImage: "link",
                                           description: Text("点击右上角 ＋ 创建。"))
                        .notificationRow()
                } else {
                    ForEach(store.hooks) { hook in
                        HStack(spacing: 12) {
                            Button { editor = Editor(webhook: hook) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(hook.name).font(.body.weight(.medium))
                                    Text(hook.channels.map(\.title).joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                            Text(hook.status).font(.caption).foregroundStyle(.secondary)
                            Menu {
                                Button("编辑", systemImage: "pencil") { editor = Editor(webhook: hook) }
                                Button(hook.enabled ? "停用" : "启用", systemImage: hook.enabled ? "pause" : "play") {
                                    if hook.enabled { confirmation = .disable(hook) }
                                    else { Task { await setEnabled(hook, enabled: true) } }
                                }
                                Button("重置 Token", systemImage: "arrow.clockwise") { confirmation = .rotate(hook) }
                                Button("删除", systemImage: "trash", role: .destructive) { confirmation = .delete(hook) }
                            } label: { Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44) }
                            .accessibilityLabel("管理 \(hook.name)")
                        }.padding(.vertical, 4).notificationRow().disabled(store.working)
                    }
                }
            } header: {
                Text("向 Sora 通知中心发送消息")
            } footer: { Text("点击名称编辑，更多菜单中可启停、重置 Token 或删除。完整地址仅在创建或重置后展示。") }
        }
        .listStyle(.insetGrouped)
        .refreshable { await store.refresh() }
    }

    private func setEnabled(_ hook: HakoWebhook, enabled: Bool) async {
        error = nil
        do {
            let saved: HakoWebhook = try await store.mutate(NotificationManagementStore.path(hook.id), method: "PATCH", body: ["enabled": enabled])
            store.update(saved)
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription + " 请刷新核对当前状态。" }
    }

    private func perform(_ action: Confirmation) async {
        error = nil
        do {
            switch action {
            case .disable(let hook): await setEnabled(hook, enabled: false)
            case .rotate(let hook):
                let result: HakoWebhookRotation = try await store.mutate(NotificationManagementStore.path(hook.id) + "/rotate-token", method: "POST")
                let address = try HakoNotificationPresentation.fullAddress(origin: store.origin, path: result.path)
                if scenePhase == .active { secret = HakoWebhookSecret(name: hook.name, address: address) }
                await store.refresh()
            case .delete(let hook):
                let _: HakoNotificationAcknowledgement = try await store.mutate(NotificationManagementStore.path(hook.id), method: "DELETE")
                store.remove(hook.id)
            }
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription + " 请刷新核对操作结果。" }
    }
}

extension View {
    func notificationRow() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
    }
}
