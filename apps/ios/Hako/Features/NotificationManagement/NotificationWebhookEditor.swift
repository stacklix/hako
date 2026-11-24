import SwiftUI
import UIKit

struct HakoWebhookEditor: View {
    @ObservedObject var store: NotificationManagementStore
    let webhook: HakoWebhook?
    let onSaved: (HakoWebhook, String?) -> Void
    @State private var draft: HakoWebhookDraft
    private let initial: HakoWebhookDraft
    @State private var error: String?
    @State private var saving = false

    init(store: NotificationManagementStore, webhook: HakoWebhook? = nil,
         onSaved: @escaping (HakoWebhook, String?) -> Void) {
        self.store = store; self.webhook = webhook; self.onSaved = onSaved
        let value = HakoWebhookDraft(webhook: webhook)
        self.initial = value; _draft = State(initialValue: value)
    }
    private var wechatID: String? { draft.botId ?? store.wechat?.connection?.id }
    private var changed: Bool { draft != initial }

    var body: some View {
        SettingsSheet(title: webhook == nil ? "创建 Webhook" : "编辑 Webhook", hasChanges: changed,
                      isBusy: saving, saveEnabled: draft.validation == nil && changed && !store.working,
                      onSave: { Task { await save() } }, saveInProgress: saving,
                      saveAccessibilityLabel: webhook == nil ? "创建并生成地址" : "保存配置") {
            Form {
                Section {
                    field("名称") {
                        TextField("例如：生产环境部署", text: $draft.name)
                            .accessibilityLabel("Webhook 名称")
                    }.notificationRow()
                }
                Section {
                    Toggle("微信", isOn: Binding(get: { draft.botId != nil }, set: { draft.botId = $0 ? wechatID : nil }))
                        .disabled(wechatID == nil).notificationRow()
                    Toggle("Apple Push", isOn: $draft.apnsEnabled).notificationRow()
                } header: { Text("允许渠道") } footer: {
                    if let channelError = store.channelError {
                        Text("无法读取微信绑定状态：\(channelError) 可下拉刷新列表后重试。")
                    } else {
                        Text(wechatID == nil ? "请先在 Sora 通知中心绑定微信。调用时必须指定一个允许的渠道。" : "调用时必须指定一个允许的渠道。图片仅支持微信。")
                    }
                }
                Section {
                    DisclosureGroup("更多选项") {
                        field("每分钟调用上限 · 1–600 次") {
                            TextField("60", text: $draft.rateLimit).keyboardType(.numberPad)
                                .accessibilityLabel("每分钟调用上限")
                        }.notificationRow()
                        Toggle("设置过期时间", isOn: $draft.hasExpiry).notificationRow()
                        if draft.hasExpiry {
                            DatePicker("过期时间", selection: $draft.expiry).notificationRow()
                        }
                    }
                }
                if let error {
                    Section { Text(error).font(.subheadline).foregroundStyle(.red).notificationRow() }
                }
                if let validation = draft.validation, changed {
                    Section { Text(validation).font(.caption).foregroundStyle(.secondary).notificationRow() }
                }
            }.disabled(saving)
        }
    }

    private func field<Content: View>(_ name: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name).font(.subheadline).foregroundStyle(.secondary)
            content()
        }.padding(.vertical, 3)
    }

    private func save() async {
        guard !saving, draft.validation == nil else { return }
        saving = true; error = nil
        defer { saving = false }
        do {
            if let webhook {
                let saved: HakoWebhook = try await store.mutate(NotificationManagementStore.path(webhook.id), method: "PATCH", body: draft.payload)
                onSaved(saved, nil)
            } else {
                let result: HakoWebhookCreation = try await store.mutate("/webhooks", method: "POST", body: draft.payload)
                // Reflect a successful creation in the list even if the
                // returned address cannot be displayed safely.
                store.update(result.webhook)
                let address = try HakoNotificationPresentation.fullAddress(origin: store.origin, path: result.path)
                onSaved(result.webhook, address)
            }
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription + " 如请求结果不确定，请关闭表单并刷新列表核对。" }
    }
}

struct HakoWebhookSecret: Identifiable {
    let id = UUID()
    let name: String
    let address: String
}

struct HakoWebhookSecretView: View {
    let secret: HakoWebhookSecret
    @State private var copied = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        SettingsSheet(title: "地址已生成") {
            Form {
                Section {
                    Label("保存你的 Webhook 地址", systemImage: "key.horizontal")
                        .font(.headline).notificationRow()
                    Text(secret.name).notificationRow()
                    Text(secret.address).font(.caption.monospaced()).textSelection(.enabled)
                        .privacySensitive().notificationRow()
                    Button(copied ? "已复制完整地址" : "复制完整地址") {
                        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: secret.address]],
                                                     options: [.localOnly: true, .expirationDate: Date.now.addingTimeInterval(120)])
                        copied = true
                    }.buttonStyle(HakoActionButtonStyle()).notificationRow()
                } footer: { Text("完整地址包含访问凭证，仅在本次展示。关闭后如未保存，需要重置 Token 生成新地址。") }
                Section {
                    Button("我已保存地址") { dismiss() }.buttonStyle(HakoActionButtonStyle(primary: false)).notificationRow()
                }
            }
        }
    }
}
