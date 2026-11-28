import SwiftUI
import Combine

/// Child apps expose configuration state, never a copy or editor of the secret.
struct HakoCredentialStatus: View {
    let key: String
    @State private var status = "正在读取"
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Text(status).font(.caption).foregroundStyle(.secondary)
            .task { load() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { load() } }
            .onReceive(NotificationCenter.default.publisher(for: HakoTokenVault.didSave).receive(on: RunLoop.main)) { _ in load() }
    }
    private func load() {
        do {
            let values = try HakoTokens.readGroup(containing: key).values
            if values.allSatisfy({ !$0.isEmpty }) { status = "已配置" }
            else if values.allSatisfy({ $0.isEmpty }) { status = "未配置" }
            else { status = "配置不完整" }
        } catch { status = "读取失败" }
    }
}
