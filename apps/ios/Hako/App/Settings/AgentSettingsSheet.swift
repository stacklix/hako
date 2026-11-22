import SwiftUI

@MainActor struct AgentSettingsSheet: View {
    private enum Editor: Identifiable {
        case add, edit(ConsoleAgent)
        var id: String { switch self { case .add: "add"; case .edit(let agent): agent.id } }
    }
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var client = DeviceMonitorClient.shared
    @State private var editor: Editor?
    @State private var scope = ""
    @State private var error: String?

    var body: some View {
        SettingsSheet(title: "Agent 管理") {
            List {
                Section {
                    LabeledContent("服务器", value: client.serverURL.isEmpty ? "未配置" : client.serverURL)
                    LabeledContent("账号", value: client.username.isEmpty ? "未登录" : client.username)
                }
                Section {
                    ForEach(client.agents) { agent in
                        Button { editor = .edit(agent) } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(agent.name).foregroundStyle(.primary)
                                    Text(agent.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    Text(agent.online ? "在线" : "离线").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!client.authenticated || client.logoutPending || client.busy)
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                    }
                    if client.agents.isEmpty {
                        Text(client.hasFetchedAgents ? "暂无登记的 Agent" : "尚未获取 Agent 列表").foregroundStyle(.secondary)
                    }
                    Button { editor = .add } label: {
                        Label("添加 Agent", systemImage: "plus")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .disabled(!client.authenticated || client.logoutPending || client.busy)
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                    Button { Task { await refresh() } } label: {
                        Text("刷新列表")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .disabled(client.busy)
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                } header: { Text("已登记设备") } footer: {
                    Text("点击 Agent 修改名称和公钥。设备管理、HTTP 代理等子应用共用此列表。")
                }
                if let error { Section { Text(error).font(.footnote).foregroundStyle(.red) } }
            }
            .refreshable { await refresh() }
        }
        .task { scope = client.serverURL + "\n" + client.username; await refresh() }
        .onChange(of: client.serverURL + "\n" + client.username) { _, _ in dismiss() }
        .sheet(item: $editor, onDismiss: { Task { await refresh() } }) { editor in
            switch editor {
            case .add: AddAgentSheet().id(client.requestContext)
            case .edit(let agent): EditAgentSheet(agent: agent).id(client.requestContext + "\n" + agent.id)
            }
        }
    }
    private func refresh() async {
        await client.restore()
        guard scope == client.serverURL + "\n" + client.username else { return }
        guard client.authenticated else { error = "请先在“服务器与登录”中登录 Sora。"; return }
        error = await client.fetchAgents() ? nil : client.message ?? "获取 Agent 列表失败。"
    }
}
