import SwiftUI

enum HeadplanePage: String, CaseIterable { case devices = "设备", network = "网络", policy = "访问控制", more = "更多" }
enum HeadplaneScreen: Identifiable {
    case settings, device(String), users, keys, createKey, dns, agent, policy, diagnostics
    var id: String {
        switch self { case .device(let id): return "device:" + id; case .settings: return "settings"; case .users: return "users"
        case .keys: return "keys"; case .createKey: return "createKey"; case .dns: return "dns"; case .agent: return "agent"; case .policy: return "policy"; case .diagnostics: return "diagnostics" }
    }
}

struct HeadplaneView: View {
    @StateObject private var store = HeadplaneStore()
    @Environment(\.scenePhase) private var scenePhase
    @State private var page = HeadplanePage.devices
    @State private var screen: HeadplaneScreen?
    @State private var search = ""
    @State private var filter = "all"
    @State private var routeChange: HeadplaneRouteChange?
    private var nodes: [HeadplaneNode] { store.machines?.nodes ?? [] }
    private var resource: HeadplaneResource { page == .policy ? .policy : .machines }
    private var refreshID: String { "\(page.rawValue)-\(scenePhase == .active)-\(screen == nil)-\(store.revision)" }
    var body: some View {
        VStack(spacing: 0) {
            header
            tabs
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if store.connection == nil {
                        ContentUnavailableView("连接你的 Headplane", systemImage: "network", description: Text("管理设备、路由与访问策略。"))
                        HeadplaneErrorText(message: store.configurationError)
                        Button("配置连接") { screen = .settings }.buttonStyle(HeadplaneButtonStyle(primary: true))
                        if store.configurationError != nil { Button("重新读取配置") { store.load() } }
                    } else {
                        HeadplaneErrorText(message: store.errors[resource])
                        if let message = store.message {
                            Text(message).font(.footnote).foregroundStyle(HeadplaneStyle.orange)
                        }
                        if let pending = store.pending {
                            Button("刷新并核对操作结果") { Task { await store.refresh(pending) } }
                                .buttonStyle(HeadplaneButtonStyle())
                        }
                        switch page {
                        case .devices: devices
                        case .network: network
                        case .policy: policy
                        case .more: more
                        }
                    }
                }.padding(.horizontal, 24).padding(.vertical, 22)
            }
            .refreshable { await store.refresh(resource) }
        }
        .background(HeadplaneStyle.background).foregroundStyle(HeadplaneStyle.text).tint(HeadplaneStyle.text)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { screen = .settings } label: { Image(systemName: "slider.horizontal.3") }
                    .accessibilityLabel("Headplane 连接设置").disabled(store.busy)
            }
        }
        .sheet(item: $screen) { selected in
            switch selected {
            case .settings: HeadplaneSettingsView(store: store)
            case .device(let id): HeadplaneDeviceView(store: store, nodeID: id, revision: store.revision)
            case .users: HeadplaneUsersView(store: store)
            case .keys: HeadplaneKeysView(store: store, revision: store.revision)
            case .createKey: HeadplaneCreateKeyView(store: store, revision: store.revision)
            case .dns: HeadplaneDNSView(store: store)
            case .agent: HeadplaneAgentView(store: store)
            case .diagnostics: HeadplaneDiagnosticsView(store: store, revision: store.revision)
            case .policy:
                if let policy = store.policy { HeadplanePolicyEditor(store: store, original: policy.text, revision: store.revision) }
            }
        }
        .alert(routeChange?.enabled == true ? "批准此路由？" : "撤销路由批准？", isPresented: Binding(get: { routeChange != nil }, set: { if !$0 { routeChange = nil } }), presenting: routeChange) { change in
            Button("取消", role: .cancel) { routeChange = nil }
            Button(change.enabled ? "确认批准" : "撤销批准", role: change.enabled ? nil : .destructive) {
                Task {
                    do { _ = try await store.mutate(.machines, revision: change.revision, fields: ["action_id": "update_routes", "node_id": change.nodeID, "routes": change.routes.joined(separator: ","), "enabled": String(change.enabled)]) }
                    catch { store.message = error.localizedDescription }
                }
            }
        } message: { change in Text(change.routes.joined(separator: "\n")) }
        .task(id: refreshID) {
            store.load()
            guard scenePhase == .active, screen == nil else { return }
            await store.refresh(resource)
            guard page == .devices || page == .network else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                if !store.busy { await store.refresh(.machines) }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text("HAKO   /   NETWORK").font(.system(size: 10, weight: .semibold)).tracking(2)
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("组网管理").font(.system(size: 29, weight: .bold)).tracking(-0.7)
                    HStack(spacing: 7) {
                        Circle().fill(store.updated[.machines] != nil && store.errors[.machines] == nil ? HeadplaneStyle.green : HeadplaneStyle.muted).frame(width: 6, height: 6)
                        Text(store.connection?.name ?? "尚未连接")
                        Text("·")
                        Text("Headplane")
                    }.font(.caption).foregroundStyle(HeadplaneStyle.muted)
                }
                Spacer(minLength: 0)
                Button { screen = .createKey } label: {
                    Label("创建密钥", systemImage: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 12).frame(minHeight: 44)
                        .foregroundStyle(HeadplaneStyle.background)
                        .background(HeadplaneStyle.text, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain).fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("创建接入密钥")
                .disabled(store.connection == nil || store.busy || store.pending != nil)
                .opacity(store.connection == nil || store.busy || store.pending != nil ? 0.35 : 1)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 25)
    }
    private var tabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 25) {
            ForEach(HeadplanePage.allCases, id: \.self) { tab in
                Button { page = tab; store.message = nil } label: {
                    Text(tab.rawValue).font(.subheadline.weight(page == tab ? .semibold : .regular))
                        .foregroundStyle(page == tab ? HeadplaneStyle.text : HeadplaneStyle.muted)
                        .frame(minHeight: 44)
                        .overlay(alignment: .bottom) { if page == tab { Rectangle().fill(HeadplaneStyle.text).frame(height: 2) } }
                }.buttonStyle(.plain).accessibilityAddTraits(page == tab ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 24)
        }.overlay(alignment: .bottom) { Rectangle().fill(HeadplaneStyle.line).frame(height: 0.5) }
    }
    private var devices: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 0) {
                stat("全部设备", count: nodes.count, value: "all")
                Rectangle().fill(HeadplaneStyle.line).frame(width: 1, height: 43)
                stat("在线", count: nodes.filter { $0.online && !$0.expired }.count, value: "online")
                Rectangle().fill(HeadplaneStyle.line).frame(width: 1, height: 43)
                stat("离线 / 过期", count: nodes.filter { !$0.online || $0.expired }.count, value: "offline")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("搜索设备").font(.caption).foregroundStyle(HeadplaneStyle.muted)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(HeadplaneStyle.muted)
                    TextField("设备名称、IP 或标签", text: $search).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("搜索设备名称、IP 或标签")
                }.font(.subheadline).padding(12).background(HeadplaneStyle.fill, in: RoundedRectangle(cornerRadius: 10))
            }
            HStack {
                Text("我的设备").font(.caption).foregroundStyle(HeadplaneStyle.muted)
                Spacer()
                Button { Task { await store.refresh(.machines) } } label: { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44) }
                    .accessibilityLabel("刷新设备").disabled(store.loading.contains(.machines))
            }
            VStack(spacing: 0) {
                ForEach(filteredNodes) { node in
                    Button { screen = .device(node.id) } label: { HeadplaneDeviceRow(node: node) }.buttonStyle(.plain)
                    if node.id != filteredNodes.last?.id { Rectangle().fill(HeadplaneStyle.line).frame(height: 0.5) }
                }
            }
            if filteredNodes.isEmpty {
                Text(store.machines == nil ? (store.loading.contains(.machines) ? "正在读取设备…" : "设备尚未加载") : nodes.isEmpty ? "还没有设备加入网络" : "没有符合条件的设备")
                    .font(.subheadline).foregroundStyle(HeadplaneStyle.muted).frame(maxWidth: .infinity).padding(.vertical, 30)
            }
            if let date = store.updated[.machines] {
                Text("更新于 \(date.formatted(date: .omitted, time: .shortened))").font(.caption2).foregroundStyle(HeadplaneStyle.muted)
            }
        }
    }
    private var filteredNodes: [HeadplaneNode] {
        nodes.filter { n in
            (filter == "all" || (filter == "online" ? n.online && !n.expired : !n.online || n.expired))
            && (search.isEmpty || ([n.name, n.userName] + n.addresses + n.tags).joined(separator: " ").localizedCaseInsensitiveContains(search))
        }
    }
    private func stat(_ title: String, count: Int, value: String) -> some View {
        Button { filter = value } label: {
            VStack(alignment: .leading, spacing: 7) {
                Text(store.machines == nil ? "—" : String(format: "%02d", count)).font(.system(size: 28, weight: .medium)).monospacedDigit()
                Text(title).font(.caption2).foregroundStyle(filter == value ? HeadplaneStyle.text : HeadplaneStyle.muted)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, value == "all" ? 0 : 18)
        }.buttonStyle(.plain).accessibilityAddTraits(filter == value ? .isSelected : [])
    }
    private var network: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("子网路由")
            ForEach(nodes.filter { !$0.subnetRoutes.isEmpty }) { node in
                VStack(alignment: .leading, spacing: 14) {
                    Text(node.name).font(.subheadline.weight(.semibold))
                    Text(node.addresses.joined(separator: " · ")).font(.caption).foregroundStyle(HeadplaneStyle.muted)
                    ForEach(node.subnetRoutes, id: \.self) { route in routeRow(node, routes: [route], approved: node.approvedRoutes.contains(route)) }
                }.headplaneCard()
            }
            if !nodes.contains(where: { !$0.subnetRoutes.isEmpty }) { empty("没有设备公布子网路由") }
            section("出口节点")
            ForEach(nodes.filter { !$0.exitRoutes.isEmpty || $0.exitApproved }) { node in
                VStack(alignment: .leading, spacing: 14) {
                    Text(node.name).font(.subheadline.weight(.semibold))
                    routeRow(node, routes: Array(Set(node.exitRoutes + node.approvedRoutes.filter(HeadplaneNode.isExit))).sorted(), approved: node.exitApproved)
                }.headplaneCard()
            }
            if !nodes.contains(where: { !$0.exitRoutes.isEmpty || $0.exitApproved }) { empty("没有可用的出口节点") }
            section("域名解析")
            menu("DNS 与 MagicDNS", subtitle: "网络域名与自定义记录", symbol: "globe") { screen = .dns }
            Text("批准路由后，客户端仍需自行选择使用。").font(.footnote).foregroundStyle(HeadplaneStyle.muted)
        }
    }
    private func routeRow(_ node: HeadplaneNode, routes: [String], approved: Bool) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Rectangle().fill(HeadplaneStyle.line).frame(height: 0.5)
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(routes.joined(separator: " · ")).font(.system(.caption, design: .monospaced))
                    Text(approved ? "已批准" : "待批准").font(.caption2).foregroundStyle(approved ? HeadplaneStyle.green : HeadplaneStyle.orange)
                }
                Spacer(minLength: 5)
                Button(approved ? "撤销" : "批准") {
                    routeChange = HeadplaneRouteChange(nodeID: node.id, routes: routes, enabled: !approved, revision: store.revision)
                }.buttonStyle(HeadplaneButtonStyle(primary: !approved)).fixedSize(horizontal: true, vertical: false)
                    .disabled(store.busy || store.pending != nil || store.machines?.writable != true)
            }
        }
    }
    private var policy: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("访问策略").font(.title3.weight(.semibold))
                    Text("管理设备之间的访问权限").font(.caption).foregroundStyle(HeadplaneStyle.muted)
                }
                Spacer()
                if let policy = store.policy { HeadplaneBadge(text: policy.writable ? "可编辑" : "只读", good: policy.writable) }
            }
            if let policy = store.policy {
                if let summary = policy.summary {
                    VStack(alignment: .leading, spacing: 13) {
                        Text("网络访问规则").font(.subheadline.weight(.semibold))
                        ForEach(Array((summary["acls"].array ?? []).enumerated()), id: \.offset) { _, rule in
                            HStack(alignment: .top) {
                                Text(rule["src"].strings.joined(separator: ", "))
                                Image(systemName: "arrow.right").foregroundStyle(HeadplaneStyle.muted)
                                Text(rule["dst"].strings.joined(separator: ", "))
                            }.font(.caption).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(HeadplaneStyle.fill, in: RoundedRectangle(cornerRadius: 10))
                        }
                        if summary["acls"].array?.isEmpty != false { Text("未定义传统 ACL 规则；完整策略请查看原文。").font(.footnote).foregroundStyle(HeadplaneStyle.muted) }
                        if let grants = summary["grants"].array { Text("另有 \(grants.count) 条 Grants 规则，见原始策略。").font(.footnote) }
                    }.headplaneCard()
                    VStack(alignment: .leading, spacing: 15) {
                        Text("用户组").font(.subheadline.weight(.semibold))
                        ForEach(summary["groups"].object.keys.sorted(), id: \.self) { key in HeadplaneFact(title: key, value: summary["groups"][key].strings.joined(separator: ", ")) }
                        Text("设备标签").font(.subheadline.weight(.semibold))
                        Text(summary["tagOwners"].object.keys.sorted().joined(separator: " · ")).font(.caption).foregroundStyle(HeadplaneStyle.muted)
                    }.headplaneCard()
                } else { empty(policy.text.isEmpty ? "尚未配置访问策略" : "此策略请通过原始文件查看") }
                Button { screen = .policy } label: { Label(policy.writable ? "编辑原始策略" : "查看原始策略", systemImage: "chevron.left.forwardslash.chevron.right") }
                    .buttonStyle(HeadplaneButtonStyle(primary: true)).disabled(store.busy || store.pending != nil)
            } else { empty(store.loading.contains(.policy) ? "正在读取访问策略…" : "策略尚未加载") }
        }
    }
    private var more: some View {
        VStack(alignment: .leading, spacing: 16) {
            section("成员与接入")
            menu("用户", subtitle: store.machines.map { "\($0.users.count) 位 Headscale 用户" } ?? "查看网络用户", symbol: "person.2") { screen = .users }
            menu("接入密钥", subtitle: "生成设备入网凭据", symbol: "key.horizontal") { screen = .keys }
            section("服务")
            menu("服务器状态与能力", subtitle: "健康检查 · 版本 · 配置状态", symbol: "heart.text.clipboard") { screen = .diagnostics }
            menu("Agent 状态", subtitle: "设备信息同步状态", symbol: "waveform.path.ecg") { screen = .agent }
            menu("连接设置", subtitle: "\(store.connection?.name ?? "") · API Key 登录", symbol: "slider.horizontal.3") { screen = .settings }
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text("Headplane").font(.subheadline.weight(.semibold)); Spacer(); Image(systemName: "network") }
                Text("设备、路由与访问控制，集中管理你的私人网络。").font(.footnote).foregroundStyle(HeadplaneStyle.muted)
            }.padding(18).background(HeadplaneStyle.fill, in: RoundedRectangle(cornerRadius: 15))
        }
    }
    private func section(_ title: String) -> some View { Text(title).font(.caption).foregroundStyle(HeadplaneStyle.muted) }
    private func empty(_ title: String) -> some View { Text(title).font(.footnote).foregroundStyle(HeadplaneStyle.muted).padding(.vertical, 12) }
    private func menu(_ title: String, subtitle: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: symbol).frame(width: 22)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.subheadline)
                    Text(subtitle).font(.caption).foregroundStyle(HeadplaneStyle.muted)
                }
                Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(HeadplaneStyle.muted)
            }.padding(.vertical, 13).contentShape(Rectangle())
        }.buttonStyle(.plain).overlay(alignment: .bottom) { Rectangle().fill(HeadplaneStyle.line).frame(height: 0.5) }
    }
}

struct HeadplaneRouteChange { let nodeID: String; let routes: [String]; let enabled: Bool; let revision: UUID }

struct HeadplaneDeviceRow: View {
    let node: HeadplaneNode
    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: node.symbol).font(.system(size: 17)).frame(width: 37, height: 37)
                .background(HeadplaneStyle.fill, in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(HeadplaneStyle.line, lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 6) {
                Text(node.name).font(.subheadline.weight(.semibold))
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 5) { ip; tag }
                    VStack(alignment: .leading, spacing: 4) { ip; tag }
                }
            }
            Spacer(minLength: 5)
            VStack(alignment: .trailing, spacing: 6) {
                HeadplaneNodeStatus(node: node)
                if !node.exitRoutes.isEmpty { Text("出口节点").font(.caption2).foregroundStyle(HeadplaneStyle.muted) }
                else if !node.subnetRoutes.isEmpty { Text("子网路由").font(.caption2).foregroundStyle(HeadplaneStyle.muted) }
                else if !node.online, let date = HeadplaneDate.parse(node.lastSeen) {
                    Text(date, style: .relative).font(.caption2).foregroundStyle(HeadplaneStyle.muted)
                }
            }.frame(maxWidth: 80, alignment: .trailing)
        }.padding(.vertical, 16).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
    private var ip: some View { Text(node.addresses.first ?? "未分配 IP").font(.caption2).foregroundStyle(HeadplaneStyle.muted).monospacedDigit() }
    private var tag: some View {
        Group {
            if let text = node.tags.first ?? (node.userName.isEmpty ? nil : node.userName) {
                Text(text).font(.system(size: 10)).foregroundStyle(HeadplaneStyle.muted)
                    .padding(.horizontal, 4).padding(.vertical, 2).background(HeadplaneStyle.fill, in: RoundedRectangle(cornerRadius: 4))
            }
        }
    }
}
