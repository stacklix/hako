import SwiftUI
import UniformTypeIdentifiers

struct EditAgentSheet: View {
    let agent: ConsoleAgent
    @ObservedObject private var client = DeviceMonitorClient.shared
    @Environment(\.dismiss) private var dismiss
    @State private var original: ConsoleAgentDetails?
    @State private var name = ""
    @State private var publicKeyPEM = ""
    @State private var loading = false
    @State private var submitting = false
    @State private var importingKey = false
    @State private var errorMessage: String?

    private var currentAgent: ConsoleAgent { client.agents.first { $0.id == agent.id } ?? agent }
    private var hasChanges: Bool {
        original?.hasChanges(name: name, publicKeyPEM: publicKeyPEM) ?? false
    }
    private var canSave: Bool {
        original != nil && hasChanges && !client.busy && client.authenticated && !client.logoutPending
            && (try? ConsoleAgentRegistration(name: name, publicKeyPEM: publicKeyPEM)) != nil
    }

    var body: some View {
        SettingsSheet(title: "编辑 Agent", hasChanges: hasChanges, isBusy: submitting,
                      saveEnabled: canSave, onSave: { Task { await save() } },
                      saveAccessibilityLabel: "保存设备信息") {
            Form {
                if loading {
                    Section { ProgressView("正在读取设备信息…") }
                } else if original != nil {
                    Section("设备信息") {
                        LabeledContent("设备 ID", value: agent.id)
                        LabeledContent("连接状态", value: currentAgent.online ? "在线" : "离线")
                        VStack(alignment: .leading, spacing: 6) {
                            Text("设备名称").font(.subheadline).foregroundStyle(.secondary)
                            TextField("输入设备名称", text: $name)
                                .accessibilityLabel("设备名称")
                        }
                    }
                    AgentDataQueryPermissionSection(client: client, agent: currentAgent)
                        .id(client.requestContext + "\n" + agent.id)
                    Section("支持能力") {
                        LabeledContent("Agent 命令", value: currentAgent.capabilities == nil ? "未声明" : currentAgent.supportsCommands ? "支持" : "不支持")
                        LabeledContent("代码工坊", value: currentAgent.modules == nil ? "未声明" : currentAgent.supportsWorkshop ? "支持" : "不支持")
                        LabeledContent("HTTP 代理", value: currentAgent.modules == nil ? "未声明" : currentAgent.supportsProxy ? "支持" : "不支持")
                    }
                    if let commands = currentAgent.capabilities, !commands.isEmpty {
                        Section("Agent 命令列表") {
                            ForEach(commands) { command in
                                LabeledContent(command.name, value: "v\(command.version)")
                                    .font(.caption.monospaced())
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                                    .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                            }
                        }
                    }
                    Section {
                        TextEditor(text: $publicKeyPEM)
                            .font(.caption.monospaced()).frame(minHeight: 180)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityLabel("Agent PEM 公钥")
                        Button { importingKey = true } label: {
                            Label("导入公钥文件", systemImage: "doc")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                    } header: {
                        Text("RSA 公钥 · PEM")
                    } footer: {
                        Text("设备 ID 不可修改。更换公钥后，Agent 需使用对应私钥重新连接。请保留完整的 BEGIN 和 END 标记。")
                    }

                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).font(.footnote).foregroundStyle(.red)
                        if original == nil {
                            Button("重新读取") { Task { await load() } }
                                .buttonStyle(HakoActionButtonStyle(primary: false))
                        }
                    }
                }
                if submitting { Section { ProgressView("正在保存设备信息…") } }
            }
            .disabled(submitting)
        }
        .task { await load() }
        .fileImporter(isPresented: $importingKey, allowedContentTypes: [.plainText, .data]) {
            importPublicKey($0)
        }
    }

    @MainActor private func load() async {
        guard !loading, original == nil else { return }
        loading = true; errorMessage = nil
        defer { loading = false }
        do {
            let details = try await client.agentDetails(agentID: agent.id)
            try Task.checkCancellation()
            original = details; name = details.name; publicKeyPEM = details.publicKeyPEM
        } catch is CancellationError { }
        catch { errorMessage = error.localizedDescription }
    }

    @MainActor private func save() async {
        guard canSave, !submitting, let original else { return }
        submitting = true; errorMessage = nil
        defer { submitting = false }
        do {
            try await client.updateAgent(original, name: name, publicKeyPEM: publicKeyPEM)
            dismiss()
        } catch is CancellationError {
            errorMessage = "保存结果尚未确认，请关闭并重新打开编辑页，核对信息后再操作。"
        } catch { errorMessage = error.localizedDescription }
    }

    private func importPublicKey(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 16 * 1024 {
                throw ConsoleAgentRegistrationError.tooLarge
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= 16 * 1024 else { throw ConsoleAgentRegistrationError.tooLarge }
            guard let text = String(data: data, encoding: .utf8) else {
                throw ConsoleAgentRegistrationError.invalidPublicKey
            }
            publicKeyPEM = try ConsoleAgentRegistration.validatePublicKey(text)
            errorMessage = nil
        } catch let error as CocoaError where error.code == .userCancelled { }
        catch { errorMessage = error.localizedDescription }
    }
}

private struct AgentDataQueryPermissionSection: View {
    @ObservedObject var client: DeviceMonitorClient
    let agent: ConsoleAgent
    @State private var saving = false
    @State private var confirmsEnabling = false
    @State private var error: String?

    var body: some View {
        Section {
            Toggle("允许查询投资账本", isOn: Binding(get: { agent.dataQueryEnabled == true }, set: { enabled in
                if enabled { confirmsEnabling = true }
                else { Task { await save(false) } }
            }))
            .disabled(saving || client.busy || !client.authenticated || client.logoutPending || !client.hasFetchedAgents || agent.dataQueryEnabled == nil)
            .frame(maxWidth: .infinity)
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
            Text(agent.name + " · " + agent.id).font(.footnote).foregroundStyle(.secondary)
            if saving { ProgressView("正在更新权限") }
            if agent.dataQueryEnabled == nil {
                Text("尚未获取权限状态，请刷新设备列表，并确认服务端已升级。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        } header: {
            Text("账本查询权限")
        } footer: {
            Text("允许此 Agent 通过 CLI 读取线上全部投资账本数据和表结构，仅支持只读查询。默认关闭；开关即时保存，下一次查询生效，离线设备也可配置。名称和公钥需另点右上角保存。")
        }
        .confirmationDialog("允许「" + agent.name + "」查询线上投资数据？", isPresented: $confirmsEnabling, titleVisibility: .visible) {
            Button("开启查询权限") { Task { await save(true) } }
            Button("取消", role: .cancel) { }
        } message: {
            Text("此设备将能够读取全部投资账户、交易、行情、汇率及快照。不会授予修改数据或访问其他数据库的权限。")
        }
    }

    private func save(_ enabled: Bool) async {
        guard !saving else { return }
        saving = true
        error = nil
        defer { saving = false }
        do { try await client.setDataQueryPermission(agentID: agent.id, enabled: enabled) }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription + " 请刷新设备列表确认实际权限后再重试。" }
    }
}
