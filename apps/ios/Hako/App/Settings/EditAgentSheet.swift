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
        guard let original else { return false }
        return name.trimmingCharacters(in: .whitespacesAndNewlines) != original.name
            || publicKeyPEM.trimmingCharacters(in: .whitespacesAndNewlines) != original.publicKeyPEM
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
