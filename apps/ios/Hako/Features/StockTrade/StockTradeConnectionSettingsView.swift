import SwiftUI

struct StockTradeConnectionSettingsView: View {
    @ObservedObject var store: StockTradeStore
    @Binding var draft: StockTradeConnection
    @Binding var message: String?
    let hasChanges: Bool
    let save: () -> Bool
    let discard: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDiscard = false

    var body: some View {
        StockTradeScreen {
            StockTradeSectionLabel(title: "独立后端")
            StockTradeCard {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("后端基础地址（HTTPS）").font(.subheadline).foregroundStyle(.secondary)
                        TextField("https://example.com/cerno/", text: $draft.origin)
                            .keyboardType(.URL).accessibilityLabel("Cerno 后端基础地址")
                    }
                    Divider()
                    HakoLabeledValue(label: "Hako 登记来源", value: draft.applicationOrigin ?? "请填写有效的 HTTPS 地址")
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Hako 应用 ID（公开）").font(.subheadline).foregroundStyle(.secondary)
                        TextField("后台登记的 clientId", text: $draft.clientID).accessibilityLabel("Cerno Hako 应用 ID")
                    }
                }
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .disabled(store.authenticating || store.loading)
            }
            StockTradeFootnote(text: "基础地址可包含应用子路径，无需追加 api/v1。登记来源使用域名根地址；应用 ID 应与后台登记一致。不填写 appSecret、Tushare 或邮件凭据。")
            if let message { StockTradeMessage(text: message) }
        }
        .navigationTitle("连接设置").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    if hasChanges { confirmingDiscard = true } else { dismiss() }
                } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("返回 Cerno 设置")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { if save() { dismiss() } } label: { Image(systemName: "checkmark") }
                    .accessibilityLabel("保存 Cerno 连接设置")
                    .disabled(!hasChanges || store.authenticating || store.loading)
            }
        }
        .onChange(of: draft) { _, _ in message = nil }
        .alert("有尚未保存的修改", isPresented: $confirmingDiscard) {
            Button("继续编辑", role: .cancel) { }
            Button("放弃并返回", role: .destructive) { discard(); dismiss() }
        } message: { Text("返回后，本次连接修改将不会保存。") }
    }
}
