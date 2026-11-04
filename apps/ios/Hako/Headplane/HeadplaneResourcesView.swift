import SwiftUI

struct HeadplaneDiagnosticsView: View {
    @ObservedObject var store: HeadplaneStore
    let revision: UUID
    private let resources: [HeadplaneResource] = [.health, .serverInfo, .settings, .serverCapabilities]
    private var checking: Bool { resources.contains { store.loading.contains($0) } }
    private func yesNo(_ value: Bool?) -> String { value.map { $0 ? "是" : "否" } ?? "未提供" }
    var body: some View {
        HeadplaneSheet(title: "服务器状态与能力") {
            if revision != store.revision {
                Text("连接已改变，请关闭后重新检查。").foregroundStyle(HeadplaneStyle.muted)
            } else {
                if checking { ProgressView("正在检查服务器…") }
                Text("健康检查").font(.headline)
                if let health = store.health {
                    HeadplaneBadge(text: health.healthy ? "服务正常" : "Headscale 健康检查异常", good: health.healthy)
                    Text(health.healthy ? "Headplane 可访问，Headscale 健康检查通过。" : "Headplane 已响应，但 Headscale 健康检查未通过。请检查后端服务及连接配置。")
                        .font(.footnote).foregroundStyle(HeadplaneStyle.muted)
                } else if !store.loading.contains(.health) {
                    Text("健康状态未知").foregroundStyle(HeadplaneStyle.muted)
                }
                HeadplaneErrorText(message: store.errors[.health])
                if let date = store.updated[.health] {
                    Text("检查于 \(date.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(HeadplaneStyle.muted)
                }

                Text("版本信息").font(.headline)
                if store.connection?.infoSecret == nil {
                    Text("尚未设置版本查询密钥。请在连接设置填写服务端的 server.info_secret 后查询。").font(.footnote).foregroundStyle(HeadplaneStyle.muted)
                } else if let info = store.serverInfo {
                    HeadplaneFact(title: "Headplane", value: info.headplaneVersion)
                    HeadplaneFact(title: "Headscale", value: info.headscaleVersion)
                    if !info.healthy { Text("版本接口报告 Headscale 不健康，Headscale 版本可能无法获取。").font(.footnote).foregroundStyle(HeadplaneStyle.orange) }
                    if !info.runtimeVersions.isEmpty {
                        DisclosureGroup("运行环境版本") {
                            VStack(spacing: 12) {
                                ForEach(info.runtimeVersions.keys.sorted(), id: \.self) { key in
                                    HeadplaneFact(title: key == "node" ? "Node.js" : key, value: info.runtimeVersions[key] ?? "")
                                }
                            }.padding(.top, 12)
                        }.font(.subheadline)
                    }
                }
                HeadplaneErrorText(message: store.errors[.serverInfo])

                Text("服务器配置能力").font(.headline)
                HeadplaneFact(title: "Headscale 配置可读", value: yesNo(store.serverCapabilities?.configReadable))
                HeadplaneErrorText(message: store.errors[.serverCapabilities])
                HeadplaneFact(title: "Headscale 配置可写", value: yesNo(store.serverSettings?.configWritable))
                HeadplaneFact(title: "Headscale OIDC 已配置", value: yesNo(store.serverSettings?.hasOIDCConfig))
                HeadplaneErrorText(message: store.errors[.settings])
                if store.serverCapabilities?.configReadable == false {
                    Text("Headplane 无法读取 Headscale 配置。请检查 headscale.config_path、文件挂载与读取权限；DNS 页面依赖这份配置。").font(.footnote).foregroundStyle(HeadplaneStyle.orange)
                } else if store.serverSettings?.configWritable == false {
                    Text("配置不可写；具体可执行的操作还取决于账号权限。").font(.footnote).foregroundStyle(HeadplaneStyle.muted)
                }
                if let capabilities = store.serverCapabilities {
                    DisclosureGroup("当前账号查看权限") {
                        VStack(spacing: 12) {
                            HeadplaneFact(title: "设备", value: yesNo(capabilities.access["machines"]))
                            HeadplaneFact(title: "DNS", value: yesNo(capabilities.access["dns"]))
                            HeadplaneFact(title: "访问策略", value: yesNo(capabilities.access["policy"]))
                            HeadplaneFact(title: "用户", value: yesNo(capabilities.access["users"]))
                            HeadplaneFact(title: "设置", value: yesNo(capabilities.access["settings"]))
                        }.padding(.top, 12)
                    }.font(.subheadline)
                }
                Button("重新检查") { Task { await refresh() } }.buttonStyle(HeadplaneButtonStyle()).disabled(checking)
            }
        }.task { await refresh() }
    }
    private func refresh() async {
        guard revision == store.revision else { return }
        await store.refreshDiagnostics()
    }
}

struct HeadplaneUsersView: View {
    @ObservedObject var store: HeadplaneStore
    var body: some View {
        HeadplaneSheet(title: "用户") {
            HeadplaneErrorText(message: store.errors[.machines])
            ForEach(store.machines?.users ?? []) { user in
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text(user.name).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(store.machines?.nodes.filter { $0.userID == user.id }.count ?? 0) 台设备").font(.caption).foregroundStyle(HeadplaneStyle.muted)
                    }
                    if !user.email.isEmpty { Text(user.email).font(.caption).foregroundStyle(HeadplaneStyle.muted) }
                    ForEach(store.machines?.nodes.filter { $0.userID == user.id } ?? []) { node in
                        HStack { Text(node.name); Spacer(); HeadplaneNodeStatus(node: node) }.font(.caption)
                    }
                }.headplaneCard()
            }
            if store.machines?.users.isEmpty == true { Text("尚无 Headscale 用户").foregroundStyle(HeadplaneStyle.muted) }
        }.task { await store.refresh(.machines) }
    }
}

struct HeadplaneDNSView: View {
    @ObservedObject var store: HeadplaneStore
    var body: some View {
        HeadplaneSheet(title: "DNS 与 MagicDNS") {
            HeadplaneErrorText(message: store.errors[.dns])
            if let data = store.values[.dns] {
                HeadplaneFact(title: "MagicDNS", value: data["magicDns"].flag ? "已启用" : "未启用")
                HeadplaneFact(title: "网络域名", value: data["baseDomain"].text)
                HeadplaneFact(title: "覆盖本地 DNS", value: data["overrideDns"].flag ? "是" : "否")
                HeadplaneFact(title: "全局 DNS", value: data["nameservers"].strings.joined(separator: "\n"))
                ForEach(data["splitDns"].object.keys.sorted(), id: \.self) { domain in
                    HeadplaneFact(title: domain, value: data["splitDns"][domain].strings.joined(separator: "\n"))
                }
                HeadplaneFact(title: "搜索域", value: data["searchDomains"].strings.joined(separator: "\n"))
                Text("自定义记录").font(.subheadline.weight(.semibold))
                ForEach(Array((data["extraRecords"].array ?? []).enumerated()), id: \.offset) { _, record in
                    HeadplaneFact(title: record["name"].text, value: record["value"].text)
                }
                Text("此版本提供只读查看，配置修改可在 Headplane 网页中完成。").font(.footnote).foregroundStyle(HeadplaneStyle.muted)
            } else if store.loading.contains(.dns) { Text("正在读取 DNS 配置…").foregroundStyle(HeadplaneStyle.muted) }
            Button("重新读取") { Task { await store.refresh(.dns) } }.buttonStyle(HeadplaneButtonStyle()).disabled(store.loading.contains(.dns))
        }.task { await store.refresh(.dns) }
    }
}

struct HeadplaneAgentView: View {
    @ObservedObject var store: HeadplaneStore
    var body: some View {
        HeadplaneSheet(title: "Agent 状态") {
            HeadplaneErrorText(message: store.errors[.agent])
            if let agent = store.agent {
                if agent.enabled {
                    HeadplaneBadge(text: agent.status, good: agent.healthy)
                    HeadplaneFact(title: "最近同步", value: HeadplaneDate.display(agent.syncedAt, empty: "尚未同步"))
                    HeadplaneFact(title: "设备数量", value: agent.nodeCountText)
                    HeadplaneErrorText(message: agent.error)
                    if agent.needsApproval {
                        Text("请在 Headplane 网页中完成 Agent 入网授权。").font(.footnote).foregroundStyle(HeadplaneStyle.muted)
                    }
                } else {
                    Text(agent.status).font(.headline)
                    Text(agent.reason).font(.footnote).foregroundStyle(HeadplaneStyle.muted)
                }
            } else if store.loading.contains(.agent) { Text("正在读取 Agent 状态…").foregroundStyle(HeadplaneStyle.muted) }
            Button("刷新状态") { Task { await store.refresh(.agent) } }.buttonStyle(HeadplaneButtonStyle()).disabled(store.loading.contains(.agent))
        }.task { await store.refresh(.agent) }
    }
}

struct HeadplaneKeysView: View {
    @ObservedObject var store: HeadplaneStore
    let revision: UUID
    @State private var expiring: HeadplaneKey?
    @State private var error: String?
    var body: some View {
        HeadplaneSheet(title: "接入密钥", busy: store.busy) {
            HeadplaneErrorText(message: error ?? store.errors[.keys])
            if let missing = store.values[.keys]?["missing"].array, !missing.isEmpty {
                HeadplaneErrorText(message: "部分用户的密钥未能读取，列表可能不完整。")
            }
            ForEach(store.keys) { key in
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(key.userName.isEmpty ? "标签接入密钥" : key.userName).font(.subheadline.weight(.semibold))
                        Spacer(); HeadplaneBadge(text: key.active ? "有效" : "已使用 / 过期", good: key.active)
                    }
                    Text("编号 \(key.id) · \(key.reusable ? "可重复使用" : "单次使用")").font(.caption).foregroundStyle(HeadplaneStyle.muted)
                    Text("到期：\(HeadplaneDate.display(key.expiry))").font(.caption).foregroundStyle(HeadplaneStyle.muted)
                    if !key.tags.isEmpty {
                        Text(key.tags.joined(separator: " · ")).font(.caption).foregroundStyle(HeadplaneStyle.muted)
                    }
                    if key.active && !key.userID.isEmpty && !key.secret.isEmpty {
                        Button("使密钥过期", role: .destructive) { expiring = key }.font(.caption)
                            .disabled(store.busy || store.pending != nil || store.values[.keys]?["access"].flag != true || revision != store.revision)
                    }
                }.headplaneCard()
            }
            if store.updated[.keys] != nil && store.keys.isEmpty { Text("尚未创建接入密钥").foregroundStyle(HeadplaneStyle.muted) }
            Button("刷新列表") { Task { await store.refresh(.keys) } }.buttonStyle(HeadplaneButtonStyle()).disabled(store.loading.contains(.keys))
        }
        .task { await store.refresh(.keys) }
        .confirmationDialog("使此接入密钥立即过期？", isPresented: Binding(get: { expiring != nil }, set: { if !$0 { expiring = nil } }), titleVisibility: .visible) {
            if let key = expiring {
                Button("确认过期", role: .destructive) {
                    Task {
                        do { _ = try await store.mutate(.keys, revision: revision, fields: ["action_id": "expire_preauthkey", "key_id": key.id, "key": key.secret, "user_id": key.userID]) }
                        catch { self.error = error.localizedDescription }
                    }
                }
            }
        } message: { Text("已加入网络的设备不受影响。") }
    }
}

struct HeadplaneCreateKeyView: View {
    @ObservedObject var store: HeadplaneStore
    let revision: UUID
    @State private var userID = ""
    @State private var tagOnly = false
    @State private var tags = ""
    @State private var days = 1
    @State private var customDays = ""
    @State private var reusable = false
    @State private var ephemeral = false
    @State private var result: String?
    @State private var error: String?
    @State private var copied = false
    private var users: [HeadplaneUser] { (store.values[.keys]?["users"].array ?? []).compactMap { try? HeadplaneUser($0) } }
    var body: some View {
        HeadplaneSheet(title: result == nil ? "创建接入密钥" : "密钥已生成", busy: store.busy) {
            if let result {
                Text("请妥善保存，此处关闭后不会保留完整密钥。").font(.footnote).foregroundStyle(HeadplaneStyle.muted)
                Text(result).font(.system(.caption, design: .monospaced)).textSelection(.enabled).headplaneCard()
                Button(copied ? "已复制" : "复制密钥") {
                    UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: result]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
                    copied = true
                }.buttonStyle(HeadplaneButtonStyle(primary: true))
            } else {
                HeadplaneErrorText(message: store.errors[.keys])
                if store.loading.contains(.keys) {
                    ProgressView("正在读取用户与权限…")
                } else if store.errors[.keys] != nil {
                    Button("重新读取") { Task { await loadUsers() } }.buttonStyle(HeadplaneButtonStyle())
                } else if store.values[.keys]?["access"].flag == false {
                    Text("当前账号没有创建接入密钥的权限。").font(.footnote).foregroundStyle(HeadplaneStyle.muted)
                }
                HeadplaneField(title: "密钥归属") {
                    Picker("密钥归属", selection: $tagOnly) {
                        Text("用户").tag(false)
                        Text("纯标签").tag(true)
                    }.pickerStyle(.segmented).accessibilityLabel("密钥归属")
                }
                if !tagOnly {
                  HeadplaneField(title: "所属用户") {
                    Picker("所属用户", selection: $userID) {
                        Text("选择用户").tag("")
                        ForEach(users) { Text($0.name).tag($0.id) }
                    }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("所属用户")
                  }
                } else {
                    Text("纯标签密钥不归属用户，至少需要一个 ACL 标签，并要求 Headscale 版本支持无用户归属的密钥。")
                        .font(.footnote).foregroundStyle(HeadplaneStyle.muted)
                }
                HeadplaneField(title: "有效期") {
                    Picker("有效期", selection: $days) { Text("24 小时").tag(1); Text("7 天").tag(7); Text("30 天").tag(30); Text("90 天").tag(90); Text("自定义").tag(0) }
                        .labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("有效期")
                }
                if days == 0 {
                    HeadplaneField(title: "有效天数") {
                        TextField("输入整数天数", text: $customDays).keyboardType(.numberPad)
                            .accessibilityLabel("有效天数")
                    }
                }
                HeadplaneField(title: tagOnly ? "ACL 标签（必填）" : "ACL 标签（可选）") {
                    TextField("例如：server, home", text: $tags, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("ACL 标签")
                }
                Text("多个标签用逗号分隔，无需填写 tag: 前缀，也支持 tag:server 这样的完整标签。使用此密钥加入的设备将携带这些标签，访问权限由 ACL 策略决定。")
                    .font(.footnote).foregroundStyle(HeadplaneStyle.muted)
                Toggle("可重复使用", isOn: $reusable)
                Toggle("临时设备", isOn: $ephemeral)
                Text("临时设备长时间离线后可能由服务器自动清理。").font(.footnote).foregroundStyle(HeadplaneStyle.muted)
                HeadplaneErrorText(message: error)
                Button(store.busy ? "正在生成…" : "生成密钥") {
                    Task {
                        do {
                            if !tagOnly && userID.isEmpty { throw HeadplaneFailure(message: "请选择所属用户。") }
                            let duration = days == 0 ? try HeadplaneKeyCreation.duration(customDays) : days
                            let fields = try HeadplaneKeyCreation.fields(userID: tagOnly ? "" : userID, tags: tags, days: duration, reusable: reusable, ephemeral: ephemeral)
                            let value = try await store.mutate(.keys, revision: revision, fields: fields)
                            guard !value["key"].text.isEmpty else { error = "密钥可能已创建，但响应未包含完整密钥。请关闭后核对列表。"; return }
                            result = value["key"].text
                        } catch { self.error = error.localizedDescription }
                    }
                }.buttonStyle(HeadplaneButtonStyle(primary: true)).disabled((!tagOnly && userID.isEmpty) || store.loading.contains(.keys) || store.errors[.keys] != nil || store.values[.keys]?["access"].flag != true || store.busy || store.pending != nil || revision != store.revision)
            }
        }.task { await loadUsers() }
    }
    private func loadUsers() async {
        await store.refresh(.keys)
        if userID.isEmpty { userID = users.first?.id ?? "" }
    }
}
