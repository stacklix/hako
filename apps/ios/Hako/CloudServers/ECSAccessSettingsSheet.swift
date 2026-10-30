import SwiftUI

struct ECSAccessSettingsSheet: View {
    let connection: ECSConnection
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var client = ConsoleClient.shared
    @State private var showingLogin = false
    @State private var domains: [String] = []
    @State private var selected: Set<String> = []
    @State private var original: Set<String> = []
    @State private var originalSource = ""
    @State private var loadedSource = ""
    @State private var loaded = false
    @State private var loading = false
    @State private var enabled = false
    @State private var error: String?
    @State private var loadID = UUID()
    private var source: String { client.serverURL + "\n" + client.username }
    private var changes: Bool { selected != original || (loaded && originalSource != loadedSource) }

    var body: some View {
        SettingsSheet(title: "访问统计设置", hasChanges: changes, isBusy: loading,
                      saveEnabled: loaded && changes && loadedSource == source && client.authenticated, onSave: save) {
            Form {
                Section("数据来源") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Hako 服务器").font(.subheadline).foregroundStyle(.secondary)
                        Text(client.serverURL.isEmpty ? "尚未配置" : client.serverURL).textSelection(.enabled)
                    }
                    LabeledContent("账号", value: client.username.isEmpty ? "未配置" : client.username)
                    Button("服务器与登录") { showingLogin = true }
                }
                Section {
                    if !client.authenticated {
                        Text("请先登录 Hako 服务器，再读取可关联的域名。").foregroundStyle(.secondary)
                    } else if loading {
                        ProgressView("读取近 7 天的域名…")
                    } else {
                        if !enabled { Text("服务端尚未启用 Caddy 访问日志统计。").foregroundStyle(.secondary) }
                        ForEach(domains, id: \.self) { domain in
                            Toggle(domain, isOn: Binding(get: { selected.contains(domain) }, set: { value in
                                if value { selected.insert(domain) } else { selected.remove(domain) }
                            })).accessibilityLabel("关联域名 \(domain)")
                        }
                        if enabled && domains.isEmpty { Text("近 7 天还没有域名记录。").foregroundStyle(.secondary) }
                    }
                } header: { Text("关联到 \(connection.name)") } footer: {
                    Text("仅选择由此 ECS 承载的域名。统计按域名汇总，后台无法自动判断域名属于哪台实例。取消全部关联后，概览不再展示统计数字。")
                }
                if let error { Section { Text(error).font(.footnote).foregroundStyle(.orange); Button("重试") { Task { await load() } } } }
            }
            .sheet(isPresented: $showingLogin) { ServerSettingsView() }
            .task(id: source + "|\(client.authenticated)|\(showingLogin)") {
                guard !showingLogin else { return }
                if !client.authenticated, !client.serverURL.isEmpty { await client.restore() }
                if client.authenticated { await load() }
            }
        }
    }

    private func load() async {
        let id = UUID(); loadID = id
        let context = source
        loading = true; loaded = false; error = nil
        defer { if loadID == id { loading = false } }
        do {
            let value = try await client.accessLogs(ECSAccessSummary.self, range: .week)
            try Task.checkCancellation()
            guard context == source, loadID == id else { return }
            let saved = ECSAccessBinding.load(connection)
            let same = saved?.matches(origin: client.serverURL, account: client.username) == true
            original = Set(saved?.domains ?? [])
            originalSource = saved.map { $0.origin + "\n" + $0.account } ?? ""
            selected = same ? original : []
            domains = Array(Set(value.domains).union(selected)).sorted()
            enabled = value.status.enabled; loadedSource = context; loaded = true
        } catch is CancellationError { }
        catch { if context == source, loadID == id { self.error = error.localizedDescription } }
    }
    private func save() {
        guard loaded, loadedSource == source else { return }
        do {
            try ECSAccessBinding(origin: client.serverURL, account: client.username, domains: Array(selected)).save(connection)
            original = selected; originalSource = source; dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
