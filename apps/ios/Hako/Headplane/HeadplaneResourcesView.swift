import SwiftUI

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
                        HStack { Text(node.name); Spacer(); Text(node.status).foregroundStyle(HeadplaneStyle.muted) }.font(.caption)
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
    @State private var creating = false
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
                    if key.active && !key.userID.isEmpty && !key.secret.isEmpty {
                        Button("使密钥过期", role: .destructive) { expiring = key }.font(.caption)
                            .disabled(store.busy || store.pending != nil || store.values[.keys]?["access"].flag != true || revision != store.revision)
                    }
                }.headplaneCard()
            }
            if store.updated[.keys] != nil && store.keys.isEmpty { Text("尚未创建接入密钥").foregroundStyle(HeadplaneStyle.muted) }
            Button("创建接入密钥") { creating = true }.buttonStyle(HeadplaneButtonStyle(primary: true))
                .disabled(store.values[.keys]?["access"].flag != true || store.busy || store.pending != nil || revision != store.revision)
            Button("刷新列表") { Task { await store.refresh(.keys) } }.buttonStyle(HeadplaneButtonStyle()).disabled(store.loading.contains(.keys))
        }
        .task { await store.refresh(.keys) }
        .sheet(isPresented: $creating) { HeadplaneCreateKeyView(store: store, revision: revision) }
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

private struct HeadplaneCreateKeyView: View {
    @ObservedObject var store: HeadplaneStore
    let revision: UUID
    @State private var userID = ""
    @State private var days = 1
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
                HeadplaneField(title: "所属用户") {
                    Picker("所属用户", selection: $userID) {
                        Text("选择用户").tag("")
                        ForEach(users) { Text($0.name).tag($0.id) }
                    }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                }
                HeadplaneField(title: "有效期") {
                    Picker("有效期", selection: $days) { Text("24 小时").tag(1); Text("7 天").tag(7); Text("30 天").tag(30); Text("90 天").tag(90) }
                        .labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                }
                Toggle("可重复使用", isOn: $reusable)
                Toggle("临时设备", isOn: $ephemeral)
                Text("临时设备长时间离线后可能由服务器自动清理。").font(.footnote).foregroundStyle(HeadplaneStyle.muted)
                HeadplaneErrorText(message: error)
                Button(store.busy ? "正在生成…" : "生成密钥") {
                    Task {
                        do {
                            let value = try await store.mutate(.keys, revision: revision, fields: ["action_id": "add_preauthkey", "user_id": userID, "expiry": String(days), "reusable": reusable ? "on" : "off", "ephemeral": ephemeral ? "on" : "off", "acl_tags": ""])
                            guard !value["key"].text.isEmpty else { error = "密钥可能已创建，但响应未包含完整密钥。请关闭后核对列表。"; return }
                            result = value["key"].text
                        } catch { self.error = error.localizedDescription }
                    }
                }.buttonStyle(HeadplaneButtonStyle(primary: true)).disabled(userID.isEmpty || store.busy || store.pending != nil || revision != store.revision)
            }
        }.onAppear { if userID.isEmpty { userID = users.first?.id ?? "" } }
    }
}
