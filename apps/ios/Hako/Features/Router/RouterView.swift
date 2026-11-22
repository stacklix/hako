import SwiftUI

struct RouterView: View {
    @StateObject private var store = RouterStore()
    @Environment(\.scenePhase) private var scenePhase
    @State private var page = RouterPage.overview
    @State private var screen: RouterScreen?
    private var refreshID: String { "\(page.rawValue)-\(store.revision)-\(scenePhase == .active)-\(screen == nil)" }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if store.connection == nil {
                    ContentUnavailableView("连接你的路由器", systemImage: "wifi.router", description: Text("查看接入设备，管理 IP/MAC 绑定与家庭网络。"))
                    Button("配置路由器连接") { screen = .settings }.buttonStyle(HakoActionButtonStyle())
                    if store.configurationError != nil { Button("重新读取配置") { store.load() } }
                } else {
                    if let message = store.message {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(message).font(.footnote).foregroundStyle(.orange)
                            Button("刷新并核对状态") { Task { await store.refresh(page.resources) } }.font(.footnote)
                        }
                    }
                    switch page {
                    case .overview: overview
                    case .devices: RouterDevicesContent(store: store, open: { screen = $0 })
                    case .network: network
                    case .tools: tools
                    }
                    if let date = store.updated {
                        Text("\(date.formatted(date: .omitted, time: .standard)) 更新\(store.fresh ? "" : " · 数据待刷新")")
                            .font(.caption).foregroundStyle(RouterStyle.muted)
                    }
                }
                if let error = store.configurationError { Text(error).font(.footnote).foregroundStyle(.orange) }
            }.padding(20)
        }
        .background(RouterStyle.background).foregroundStyle(RouterStyle.text).tint(RouterStyle.text)
        .navigationTitle("").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await store.refresh(page.resources) } } label: {
                    if store.busy { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                }.accessibilityLabel("刷新路由器状态").disabled(store.busy || store.connection == nil)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { screen = .settings } label: { Image(systemName: "slider.horizontal.3") }
                    .accessibilityLabel("路由器连接设置").disabled(store.busy)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 0) {
                ForEach(RouterPage.allCases) { item in
                    Button { page = item } label: {
                        VStack(spacing: 5) {
                            Image(systemName: item.symbol).font(.system(size: 20, weight: page == item ? .semibold : .regular))
                            Text(item.rawValue).font(.caption2)
                        }.foregroundStyle(page == item ? RouterStyle.text : RouterStyle.muted).frame(maxWidth: .infinity).padding(.vertical, 12)
                    }.buttonStyle(.plain).accessibilityAddTraits(page == item ? .isSelected : []).disabled(store.busy)
                }
            }.background(RouterStyle.panel).overlay(alignment: .top) { Divider() }
        }
        .refreshable { await store.refresh(page.resources) }
        .task(id: refreshID) {
            store.load()
            guard scenePhase == .active, screen == nil else { return }
            await store.refresh(page.resources)
        }
        .sheet(item: $screen) { selection in
            switch selection {
            case .settings: RouterSettingsView(store: store)
            case .bindings: RouterBindingsView(store: store)
            case .device(let mac): RouterDeviceView(store: store, mac: mac)
            case .resource(let resource): RouterResourceView(store: store, resource: resource)
            }
        }
    }
    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(page == .overview ? "路由器" : page.rawValue).font(.largeTitle.bold())
                Text(store.value(.hardware)["device_info"]["info"]["device_model"].text.isEmpty ? "TP-LINK · \(store.connection?.address ?? "192.168.0.1")" : store.value(.hardware)["device_info"]["info"]["device_model"].text)
                    .font(.caption).foregroundStyle(RouterStyle.muted)
                if store.connection != nil {
                    Text(store.route?.title ?? "自动选择连接").font(.caption2).foregroundStyle(RouterStyle.muted)
                }
            }
            Spacer(minLength: 0)
            RouterBadge(text: store.busy ? "读取中" : store.fresh ? "已连接" : "未连接", good: store.fresh && !store.busy)
        }
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 20) {
            RouterPanel {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("我的家庭网络").font(.caption).foregroundStyle(RouterStyle.muted)
                            Text(wan["link_status"].enabled ? "网络已连接" : "等待网络状态").font(.title3.weight(.semibold))
                            HStack {
                                RouterBadge(text: "IPv4", good: wan["link_status"].enabled)
                                RouterBadge(text: "IPv6", good: store.value(.wan)["network"]["wanv6_status"]["link_status"].enabled)
                            }
                        }
                        Spacer()
                        Image(systemName: "wifi.router").font(.system(size: 40, weight: .ultraLight)).accessibilityHidden(true)
                    }
                    Divider()
                    HStack {
                        speedFact("当前下载", speed: wan["down_speed"].text)
                        Spacer()
                        speedFact("当前上传", speed: wan["up_speed"].text)
                    }
                    if let error = store.errors[.wan] { Text(error).font(.caption).foregroundStyle(.orange) }
                }.padding(20)
            }
            RouterPanel {
                HStack(spacing: 0) {
                    countButton("在线设备", count: store.snapshot.map { String($0.onlineDevices.count) } ?? "—") { page = .devices }
                    Divider()
                    countButton("IP/MAC 绑定", count: store.snapshot.map { String($0.bindings.count) } ?? "—") { screen = .bindings }
                    Divider()
                    countButton("组网节点", count: store.resources[.mesh].map { String($0["hyfi"]["connected_ext"].array.count + 1) } ?? "—") { screen = .resource(.mesh) }
                }.padding(.vertical, 17)
            }
            RouterSection(title: "常用功能") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    quick("IP/MAC 绑定", subtitle: "管理设备地址关系", symbol: "link") { screen = .bindings }
                    quick("访客网络", subtitle: "独立接入与开放时间", symbol: "wifi") { screen = .resource(.guest) }
                    quick("端口状态", subtitle: "连接方式与协商速率", symbol: "cable.connector") { screen = .resource(.ports) }
                    quick("上网规则", subtitle: "时段与访问管理", symbol: "clock") { screen = .resource(.behavior) }
                }
            }
            RouterSection(title: "活跃设备") {
                RouterPanel {
                    ForEach(Array((store.snapshot?.onlineDevices ?? []).sorted { $0.download + $0.upload > $1.download + $1.upload }.prefix(3))) { device in
                        RouterDeviceRow(device: device, bound: store.snapshot?.bindings.contains { $0.mac == device.mac } == true) { screen = .device(device.mac) }
                    }
                    if store.snapshot?.onlineDevices.isEmpty == true { Text("暂无在线设备").font(.subheadline).foregroundStyle(RouterStyle.muted).padding(24) }
                }
                Button("查看全部设备") { page = .devices }.font(.footnote)
            }
        }.disabled(store.busy)
    }
    private var wan: RouterJSON { store.value(.wan)["network"]["wan_status"] }
    private func speedFact(_ title: String, speed: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption).foregroundStyle(RouterStyle.muted)
            Text(Double(speed).map(RouterDisplay.speed) ?? "—").font(.title3.monospacedDigit().weight(.medium))
        }
    }
    private func countButton(_ title: String, count: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) { Text(count).font(.title2.monospacedDigit().weight(.semibold)); Text(title).font(.caption2).foregroundStyle(RouterStyle.muted) }
                .frame(maxWidth: .infinity)
        }.buttonStyle(.plain)
    }
    private func quick(_ title: String, subtitle: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 30, height: 34).background(RouterStyle.fill, in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 4) { Text(title).font(.caption.weight(.semibold)); Text(subtitle).font(.caption2).foregroundStyle(RouterStyle.muted) }
                Spacer(minLength: 0)
            }.padding(13).frame(maxWidth: .infinity, minHeight: 72, alignment: .leading).background(RouterStyle.panel, in: RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain)
    }
    private func menu(_ title: String, symbol: String, subtitle: String = "", value: String = "", resource: RouterResource, last: Bool = false) -> some View {
        RouterMenuRow(title: title, symbol: symbol, subtitle: subtitle, value: value, separator: !last) { screen = .resource(resource) }
    }
    private var network: some View {
        VStack(alignment: .leading, spacing: 24) {
            RouterSection(title: "无线网络") {
                RouterPanel {
                    menu("主 Wi-Fi", symbol: "wifi", subtitle: "2.4 GHz / 5 GHz 与双频合一", resource: .wireless)
                    menu("访客网络", symbol: "person.2.wave.2", subtitle: "独立接入与开放时间", resource: .guest)
                    menu("无线定时", symbol: "clock", resource: .wirelessSchedule)
                    menu("无线接入控制", symbol: "checkmark.shield", resource: .access, last: true)
                }
            }
            RouterSection(title: "局域网") {
                RouterPanel {
                    RouterMenuRow(title: "IP/MAC 绑定", symbol: "link", value: "\(store.snapshot?.bindings.count ?? 0) 条") { screen = .bindings }
                    menu("DHCP 与 LAN", symbol: "list.bullet.rectangle", subtitle: store.connection?.address ?? "", resource: .dhcp)
                    menu("IPv6 与互联网", symbol: "network", resource: .wan)
                    menu("易展 Mesh", symbol: "point.3.connected.trianglepath.dotted", resource: .mesh, last: true)
                }
            }
            RouterSection(title: "物理连接") {
                RouterPanel {
                    ForEach(RouterPort.all(store.value(.ports))) { port in
                        RouterMenuRow(title: "\(port.name) · \(port.role)", symbol: "cable.connector", value: port.rate) { screen = .resource(.ports) }
                    }
                }
                if let error = store.errors[.ports] { Text(error).font(.caption).foregroundStyle(.orange) }
            }
        }.disabled(store.busy)
    }
    private var tools: some View {
        VStack(alignment: .leading, spacing: 24) {
            RouterSection(title: "网络服务") {
                RouterPanel {
                    menu("端口转发", symbol: "arrow.left.arrow.right", subtitle: "手动映射局域网服务", resource: .forward)
                    menu("UPnP", symbol: "arrow.triangle.branch", subtitle: "设备自动申请的端口映射", resource: .upnp)
                    menu("DDNS", symbol: "globe", resource: .ddns)
                    menu("DMZ 主机", symbol: "desktopcomputer.and.arrow.down", resource: .dmz)
                    menu("远程唤醒", symbol: "power", resource: .wake, last: true)
                }
            }
            RouterSection(title: "上网与组网") {
                RouterPanel {
                    menu("上网规则", symbol: "clock.badge.checkmark", resource: .behavior)
                    menu("双 WAN / IPTV / 聚合", symbol: "cable.connector", resource: .advanced, last: true)
                }
            }
            RouterSection(title: "路由器管理") {
                RouterPanel {
                    menu("自动清理", symbol: "clock.arrow.circlepath", resource: .maintenance)
                    menu("系统日志", symbol: "list.bullet.rectangle", resource: .logs)
                    menu("系统与诊断", symbol: "info.circle", resource: .hardware)
                    menu("路由器能力", symbol: "checkmark.seal", resource: .capabilities, last: true)
                }
            }
        }.disabled(store.busy)
    }
}
