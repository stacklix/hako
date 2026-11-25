import SwiftUI

struct StockTradeDeviceAuthorizations: View {
    @ObservedObject var store: StockTradeStore
    private struct Device: Decodable, Identifiable {
        let deviceId, createdAt, lastUsedAt: String
        var id: String { deviceId }
    }
    private struct Response: Decodable { let items: [Device] }
    @State private var devices: [Device] = []
    @State private var error: String?
    @State private var loading = false
    @State private var scope: UUID?
    var body: some View {
        StockTradeScreen {
            StockTradeHeading(title: "设备授权", subtitle: "查看 Cerno 登录设备")
            if let error { StockTradeMessage(text: error) }
            StockTradeCard {
                if scope == store.scope {
                    ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("设备 " + String(device.deviceId.prefix(8))).font(.headline)
                                Spacer()
                                if device.deviceId == store.session?.deviceId { Text("当前设备").font(.caption).foregroundStyle(StockTradeAppearance.tint) }
                            }
                            Text("登记 " + StockTradeTime.display(device.createdAt)).font(.caption).foregroundStyle(.secondary)
                            Text("最近使用 " + StockTradeTime.display(device.lastUsedAt)).font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 12)
                        if index < devices.count - 1 { Divider() }
                    }
                }
                if loading { ProgressView("读取设备授权…").padding(.vertical, 16) }
                else if devices.isEmpty && error == nil { Text("暂无已授权设备。").font(.subheadline).foregroundStyle(.secondary) }
            }
            StockTradeFootnote(text: "当前设备可从连接设置退出并撤销续期；完整应用授权可在 Hako 中管理。")
        }.task(id: store.scope) { devices = []; scope = store.scope; await load() }.refreshable { await load() }
    }
    private func load() async {
        let current = store.scope
        loading = true
        defer { if current == store.scope { loading = false } }
        do {
            let response = try await store.read(["auth", "native", "devices"], as: Response.self)
            guard current == store.scope else { return }
            guard Set(response.items.map(\.id)).count == response.items.count,
                  response.items.allSatisfy({ $0.deviceId.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil }) else { throw StockTradeFailure.invalidResponse }
            devices = response.items; error = nil
        } catch is CancellationError { }
        catch { if current == store.scope { self.error = error.localizedDescription } }
    }
}
