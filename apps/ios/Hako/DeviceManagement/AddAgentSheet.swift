import SwiftUI
import UniformTypeIdentifiers

struct AddAgentSheet: View {
    @ObservedObject private var client = ConsoleClient.shared
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var publicKeyPEM = ""
    @State private var importingKey = false
    @State private var submitting = false
    @State private var errorMessage: String?

    private var missingInput: Bool {
        [name, publicKeyPEM].contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("服务器", value: client.serverURL)
                    LabeledContent("账号", value: client.username)
                }
                Section {
                    TextField("设备名称，例如我的设备", text: $name)
                        .accessibilityLabel("设备名称")
                } header: { Text("设备信息") }
                Section {
                    TextEditor(text: $publicKeyPEM)
                        .font(.caption.monospaced()).frame(minHeight: 180)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("Agent PEM 公钥")
                    Button { importingKey = true } label: { Label("导入公钥文件", systemImage: "doc") }
                } header: { Text("RSA 公钥 · PEM") } footer: {
                    Text("粘贴或导入 Agent 导出的 PEM 公钥（RSA 2048–8192 位），保留完整的 BEGIN 和 END 标记。")
                }
                if let errorMessage {
                    Section { Text(errorMessage).font(.footnote).foregroundStyle(.red) }
                }
                if !client.authenticated {
                    Section { Text("登录已失效，请返回设置重新登录后添加。").foregroundStyle(.secondary) }
                }
                if submitting { Section { ProgressView("正在添加 Agent…") } }
            }
            .disabled(submitting)
            .navigationTitle("添加 Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.disabled(submitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") { Task { await submit() } }
                        .disabled(submitting || client.busy || !client.authenticated || missingInput)
                }
            }
        }
        .interactiveDismissDisabled(submitting)
        .fileImporter(isPresented: $importingKey, allowedContentTypes: [.plainText, .data]) { result in
            importPublicKey(result)
        }
    }

    @MainActor private func submit() async {
        guard !submitting else { return }
        submitting = true; errorMessage = nil
        defer { submitting = false }
        do {
            try await client.addAgent(name: name, publicKeyPEM: publicKeyPEM)
            dismiss()
        } catch is CancellationError {
            errorMessage = "请求已取消，登记结果尚未确认。请刷新设备列表，确认后再重试。"
        } catch {
            errorMessage = error.localizedDescription
        }
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
            guard let text = String(data: data, encoding: .utf8) else { throw ConsoleAgentRegistrationError.invalidPublicKey }
            publicKeyPEM = try ConsoleAgentRegistration.validatePublicKey(text)
            errorMessage = nil
        } catch let error as CocoaError where error.code == .userCancelled {
            // Cancelling the document picker preserves the form.
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
