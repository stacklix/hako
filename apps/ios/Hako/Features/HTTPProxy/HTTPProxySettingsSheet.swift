import SwiftUI

@MainActor struct HTTPProxySettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let authentication = AuthenticatedServerService.shared
    @State private var agents: [ConsoleAgent] = []
    @State private var loading = false
    @State private var selected = ""
    @State private var saved = ""
    @State private var scope = ""
    @State private var error: String?

    private var key: String { HakoHTTPProxy.settingsKey(server: authentication.serverURL, account: authentication.username) }
    private var candidates: [ConsoleAgent] {
        agents.filter(\.supportsProxy)
    }
    var body: some View {
        SettingsSheet(title: "HTTP 代理", hasChanges: selected != saved,
                      saveEnabled: scope == authentication.requestContext, onSave: save) {
            Form {
                Section {
                    Picker("代理 Agent", selection: $selected) {
                        Text("未配置").tag("")
                        if !selected.isEmpty, !candidates.contains(where: { $0.id == selected }) {
                            Text("已选设备 · 不可用（\(selected)）").tag(selected)
                        }
                        ForEach(candidates) { agent in
                            Text(agent.name + (agent.online ? " · 在线" : " · 离线")).tag(agent.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                    .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                    Button("刷新 Agent") { Task { await refresh() } }
                        .disabled(loading)
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                } header: { Text("转发设备") } footer: {
                    Text("选择支持 HTTP 代理的 Agent。配置按 Sora 服务器和账号分别保存；离线时请求报错。")
                }
                Section("请求规则") {
                    Text("请求携带 X-Proxy: 192.168.1.10:8080 时，经 Sora 和所选 Agent 转发。没有该头的请求继续直连。")
                    Text("保留原 URL 的 HTTP/HTTPS 协议、路径及查询参数，使用头中的 IP 和端口连接。IPv6 示例：[fd00::1]:8080。")
                    Text("请求体最多 512 KiB，响应最多 8 MiB；目标请求最多 8 秒。响应完整返回，不支持实时流式响应或 WebSocket 升级。")
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
        }
        .task {
            scope = authentication.requestContext
            selected = UserDefaults.standard.string(forKey: key) ?? ""
            saved = selected
            await refresh()
        }
        .onReceive(authentication.changes) { if scope != authentication.requestContext { dismiss() } }
    }
    private func refresh() async {
        await authentication.restore()
        if !authentication.authenticated { error = "请先登录 Sora 服务器。"; return }
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let result = try await HakoAgents.list(refresh: true)
            guard !Task.isCancelled, scope == authentication.requestContext else { return }
            agents = result
            error = candidates.isEmpty ? "暂无支持代理的 Agent，请升级 Kage 后刷新。" : nil
        } catch {
            if !Task.isCancelled, scope == authentication.requestContext { self.error = error.localizedDescription }
        }
    }
    private func save() {
        guard scope == authentication.requestContext else { return }
        UserDefaults.standard.set(selected, forKey: key)
        dismiss()
    }
}
