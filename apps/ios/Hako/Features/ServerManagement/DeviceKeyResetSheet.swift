import SwiftUI

struct DeviceKeyResetSheet: View {
    @ObservedObject private var client = ConsoleClient.shared
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("旧密钥不可恢复", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                    Text("确认后将生成新密钥并退出本机 Hako 服务器登录。请重新导出公钥，替换服务端旧公钥并重启服务后重新登录。")
                        .font(.footnote)
                }
                Section {
                    Button("确认重置密钥对", role: .destructive) {
                        Task { await resetKeyPair() }
                    }
                    .foregroundStyle(.red)
                    .disabled(client.busy)
                }
                if client.resettingKey { ProgressView("正在重置密钥对…") }
                if let errorMessage {
                    Section { Text(errorMessage).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("重置密钥对")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.disabled(client.resettingKey)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(client.resettingKey)
    }

    @MainActor private func resetKeyPair() async {
        errorMessage = nil
        let previousID = client.deviceId
        await client.resetKeyPair()
        if client.deviceId != previousID { dismiss() }
        else { errorMessage = client.message ?? "未能重置密钥对，请稍后重试。" }
    }
}
