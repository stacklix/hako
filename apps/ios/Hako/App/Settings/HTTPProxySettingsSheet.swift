import SwiftUI

@MainActor struct HTTPProxySettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var devices = DeviceMonitorClient.shared
    @State private var selected = ""
    @State private var saved = ""
    @State private var scope = ""
    @State private var error: String?

    private var key: String { HakoHTTPProxy.settingsKey(server: devices.serverURL, account: devices.username) }
    private var candidates: [ConsoleAgent] {
        devices.agents.filter { $0.capabilities?.contains { $0.name == HakoHTTPProxy.command && $0.version == 1 } == true }
    }
    var body: some View {
        SettingsSheet(title: "HTTP 代理", hasChanges: selected != saved,
                      saveEnabled: scope == devices.requestContext, onSave: save) {
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
                        .disabled(devices.busy)
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
            scope = devices.requestContext
            selected = UserDefaults.standard.string(forKey: key) ?? ""
            saved = selected
            await refresh()
        }
        .onChange(of: devices.requestContext) { _, _ in dismiss() }
    }
    private func refresh() async {
        await devices.restore()
        if !devices.authenticated { error = "请先登录 Sora 服务器。"; return }
        if await devices.fetchAgents() { error = candidates.isEmpty ? "暂无支持代理的 Agent，请升级 Kage 后刷新。" : nil }
        else { error = devices.message ?? "刷新 Agent 失败。" }
    }
    private func save() {
        guard scope == devices.requestContext else { return }
        UserDefaults.standard.set(selected, forKey: key)
        dismiss()
    }
}
