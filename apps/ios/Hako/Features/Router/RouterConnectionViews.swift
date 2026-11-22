import SwiftUI

struct RouterSettingsView: View {
    @ObservedObject var store: RouterStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft = RouterConnection()
    @State private var original = RouterConnection()
    @State private var error: String?
    @State private var removing = false

    var body: some View {
        SettingsSheet(title: "路由器连接设置", hasChanges: draft != original, isBusy: store.busy,
                      saveEnabled: !draft.password.isEmpty && !store.pending && store.configurationError == nil,
                      onSave: connect, saveAccessibilityLabel: "验证并保存路由器连接") {
            Form {
                Section {
                    LabeledContent("连接方式", value: "自动选择")
                    if let route = store.route { LabeledContent("当前链路", value: route.title) }
                } footer: {
                    Text("根据主应用的网络环境自动选择：内网直连，外网经 Sora 和家中在线的 Agent 访问。请在主应用“设置 → 网络配置”登记家中 Wi-Fi，并在“HTTP 代理”中选择 Agent；此处始终填写路由器的局域网地址。")
                }
                Section {
                    RouterField(title: "路由器 IPv4 地址") {
                        TextField("192.168.0.1", text: $draft.address).keyboardType(.decimalPad)
                            .accessibilityLabel("路由器 IPv4 地址")
                    }
                    RouterField(title: "管理员密码") {
                        SecureField("路由器管理页面的登录密码", text: $draft.password)
                            .accessibilityLabel("路由器管理员密码")
                    }
                } header: { Text("TP-LINK · TL-XDR5480 易展 Turbo 版") }
                footer: {
                    Text("密码保存在本机系统钥匙串。代理时登录数据与响应经 Sora 和所选 Agent 转发；路由器侧使用 HTTP。验证成功后保存配置。")
                }
                if let error = error ?? store.configurationError { Section { Text(error).foregroundStyle(.orange) } }
                Section {
                    Button(store.busy ? "正在验证…" : "验证并保存") { connect() }
                        .buttonStyle(HakoActionButtonStyle())
                        .frame(maxWidth: .infinity)
                        .disabled(store.busy || store.pending || draft.password.isEmpty || store.configurationError != nil)
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                    if store.configurationError != nil {
                        Button("重新读取原配置") { store.load() }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                            .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                    }
                    if store.connection != nil {
                        Button(role: .destructive) { removing = true } label: {
                            Text("移除已保存的连接")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .disabled(store.busy || store.pending)
                            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                            .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                    }
                }
                if store.pending { Section { Text("请返回路由器页面刷新，核对上次操作结果后再修改连接。") } }
            }.textInputAutocapitalization(.never).autocorrectionDisabled()
        }
        .onAppear {
            draft = store.connection ?? RouterConnection(); original = draft
        }
        .alert("移除已保存的连接？", isPresented: $removing) {
            Button("取消", role: .cancel) { }
            Button("移除", role: .destructive) {
                do { try store.disconnect(); dismiss() } catch { self.error = error.localizedDescription }
            }
        } message: { Text("仅移除保存的地址与密码，路由器设置保持不变。") }
    }
    private func connect() {
        Task {
            error = nil
            do { try await store.connect(draft); dismiss() }
            catch { self.error = error.localizedDescription }
        }
    }
}

struct RouterBindingEditor: View {
    @ObservedObject var store: RouterStore
    let original: RouterBinding?
    let initial: RouterBindingDraft
    @Environment(\.dismiss) private var dismiss
    @State private var draft = RouterBindingDraft()
    @State private var error: String?
    @State private var confirming = false
    private var validation: String? {
        guard let snapshot = store.snapshot else { return "请先刷新路由器状态。" }
        do { _ = try draft.validated(in: snapshot, replacing: original?.id); return nil }
        catch { return error.localizedDescription }
    }
    var body: some View {
        SettingsSheet(title: original == nil ? "新增 IP/MAC 绑定" : "编辑 IP/MAC 绑定",
                      hasChanges: draft != initial, isBusy: store.busy,
                      saveEnabled: store.bindingsWritable && validation == nil && (original == nil || draft != initial),
                      onSave: { confirming = true }, saveAccessibilityLabel: "确认 IP/MAC 绑定") {
            Form {
                Section {
                    RouterField(title: "设备名称（可选）") {
                        TextField("例如：客厅电视", text: $draft.name).accessibilityLabel("设备名称")
                    }
                    RouterField(title: "IP 地址") {
                        TextField("192.168.0.100", text: $draft.ip).keyboardType(.decimalPad).accessibilityLabel("绑定 IP 地址")
                    }
                    RouterField(title: "MAC 地址") {
                        TextField("02:11:22:33:44:55", text: $draft.mac).accessibilityLabel("绑定 MAC 地址")
                    }
                } footer: { Text("保存会修改路由器的 IP/MAC 绑定。使用随机 Wi-Fi 地址的设备需保持该网络的 MAC 地址稳定。") }
                if let validation { Section { Text(validation).font(.footnote).foregroundStyle(.secondary) } }
                if let error { Section { Text(error).foregroundStyle(.orange) } }
                if !store.fresh || store.pending {
                    Section {
                        Button("刷新并核对绑定") { Task { await store.refresh() } }.disabled(store.busy)
                    }
                }
            }.textInputAutocapitalization(.never).autocorrectionDisabled()
        }
        .onAppear { draft = initial }
        .alert("保存此 IP/MAC 绑定？", isPresented: $confirming) {
            Button("取消", role: .cancel) { }
            Button("确认保存") {
                Task {
                    do { try await store.save(draft, replacing: original); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
            }
        } message: { Text("\(draft.ip)\n\(draft.mac)\n保存后会回查路由器上的绑定记录。") }
    }
}

struct RouterField<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            content
        }.frame(maxWidth: .infinity, alignment: .leading)
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
    }
}
