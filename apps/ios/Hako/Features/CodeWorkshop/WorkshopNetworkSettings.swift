import SwiftUI

struct WorkshopComputerSettingsRow: View {
    @ObservedObject var store: WorkshopStore
    let agent: WorkshopAgent

    var body: some View {
        Button { Task { await store.selectAgent(agent.id) } } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(agent.name).foregroundStyle(.primary)
                    Text(agent.online ? "在线" : "离线").font(.caption).foregroundStyle(.secondary)
                    if let endpoint = store.localEndpoint(for: agent.id) {
                        Text("局域网直连 · " + endpoint.address).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if agent.id == store.selectedAgentID { Image(systemName: "checkmark") }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.borderless).disabled(store.loading)
        .accessibilityLabel("选择执行电脑" + agent.name)
        .accessibilityAddTraits(agent.id == store.selectedAgentID ? .isSelected : [])
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
    }
}
