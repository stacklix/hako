import SwiftUI
import UIKit

struct ConsoleApplicationSecretView: View {
    @ObservedObject var client: ConsoleApplicationsClient
    let credential: ConsoleApplicationCredential
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var revealed = false
    @State private var confirmingClose = false
    @State private var copied = false
    private var valid: Bool { client.authenticated && credential.context == client.context }
    var body: some View {
        NavigationStack {
            Form {
                if valid {
                    Section {
                        Label("Client Secret 仅显示这一次", systemImage: "key.horizontal").font(.headline)
                        Text("请保存到应用后端。关闭后无法再次查看；遗失时需要轮换。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section(credential.application.name) {
                        HakoLabeledValue(label: "Issuer", value: credential.issuer, monospaced: true)
                        HakoLabeledValue(label: "Client ID", value: credential.application.id, monospaced: true)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Client Secret").font(.subheadline).foregroundStyle(.secondary)
                            HStack(alignment: .top, spacing: 12) {
                                if revealed {
                                    Text(credential.secret).font(.footnote.monospaced()).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                } else {
                                    SecureField("Client Secret", text: .constant(credential.secret))
                                        .disabled(true).font(.footnote.monospaced()).accessibilityLabel("Client Secret，已隐藏")
                                }
                                Button { revealed.toggle() } label: { Image(systemName: revealed ? "eye.slash" : "eye") }
                                    .buttonStyle(.borderless).accessibilityLabel(revealed ? "隐藏 Client Secret" : "显示 Client Secret")
                            }
                        }
                    }.privacySensitive()
                    Section {
                        Button {
                            guard valid else { return }
                            UIPasteboard.general.setItems([["public.utf8-plain-text": credential.application.configuration(issuer: credential.issuer, secret: credential.secret)]], options: [.localOnly: true])
                            copied = true
                        } label: { Label(copied ? "已复制完整接入配置" : "复制完整接入配置", systemImage: copied ? "checkmark" : "doc.on.doc") }
                        Button { confirmingClose = true } label: { Label("已保存，完成", systemImage: "checkmark") }
                    } header: { Text("保存与配置") }
                } else {
                    ContentUnavailableView("凭据页面已关闭", systemImage: "lock", description: Text("当前服务器或登录状态已变化。"))
                }
            }
            .navigationTitle("保存应用凭据").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { confirmingClose = true } label: { Image(systemName: "xmark") }.accessibilityLabel("关闭凭据页面")
                }
            }
            .alert("已保存 Client Secret？", isPresented: $confirmingClose) {
                Button("已保存并关闭") { dismiss() }
                Button("继续查看", role: .cancel) { }
            } message: { Text("关闭后无法再次查看，遗失时只能轮换生成新的 Secret。") }
        }
        .interactiveDismissDisabled()
        .onChange(of: client.context) { _, _ in revealed = false; dismiss() }
        .onChange(of: scenePhase) { _, value in if value != .active { revealed = false } }
    }
}
