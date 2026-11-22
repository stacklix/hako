import SwiftUI

struct RouterResourceView: View {
    @ObservedObject var store: RouterStore
    let resource: RouterResource
    var deviceMAC: String? = nil
    @State private var editor: RouterConfigurationEditorSelection?
    @State private var confirming: RouterConfigurationChange?
    @State private var rebooting = false
    @State private var waking: String?
    @State private var wakeEditor = false
    @State private var error: String?
    private var data: RouterJSON { store.value(resource) }
    private var ready: Bool { store.canEdit(resource) }
    var body: some View {
        SettingsSheet(title: resource.title, isBusy: store.busy) {
            Form {
                if let error = error ?? store.errors[resource] { Section { Text(error).font(.footnote).foregroundStyle(.orange) } }
                if store.resources[resource] != nil {
                    if !store.freshResources.contains(resource) { Section { Text("以下为上次读取的信息，请刷新后再修改。").font(.footnote).foregroundStyle(.secondary) } }
                    content
                } else if store.busy { Section { ProgressView("正在读取\(resource.title)…") } }
                else { Section { Text("尚未读取此功能，请刷新。").foregroundStyle(.secondary) } }
                Section {
                    if let message = store.message { Text(message).font(.footnote).foregroundStyle(.orange) }
                    if let date = store.resourceDates[resource] { Text("更新于 \(date.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary) }
                    Button("刷新并核对状态") { Task { await store.refresh([resource]) } }.disabled(store.busy)
                }
            }.refreshable { await store.refresh([resource]) }
        }
        .task { await store.refresh([resource]) }
        .sheet(item: $editor) { selection in RouterConfigurationEditor(store: store, resource: resource, selection: selection) }
        .sheet(isPresented: $wakeEditor) { RouterWakeView(store: store) }
        .alert(confirming?.kind == .delete ? "删除此配置？" : "保存此配置？", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), presenting: confirming) { change in
            Button("取消", role: .cancel) { confirming = nil }
            Button(change.kind == .delete ? "删除" : "保存", role: change.kind == .delete ? .destructive : nil) {
                Task { do { try await store.apply(change); error = nil } catch { self.error = error.localizedDescription }; confirming = nil }
            }
        } message: { _ in Text("操作会修改路由器配置，并重新读取确认结果。") }
        .alert("重启路由器？", isPresented: $rebooting) {
            Button("取消", role: .cancel) { }
            Button("重启", role: .destructive) { Task { do { try await store.reboot() } catch { self.error = error.localizedDescription } } }
        } message: { Text("所有网络连接将暂时中断。等待网络恢复后，请刷新确认。") }
        .alert("发送唤醒请求？", isPresented: Binding(get: { waking != nil }, set: { if !$0 { waking = nil } })) {
            Button("取消", role: .cancel) { waking = nil }
            Button("发送") { if let mac = waking { Task { do { try await store.wake(mac: mac) } catch { self.error = error.localizedDescription }; waking = nil } } }
        } message: { Text("\(waking ?? "")\n目标设备及网卡须支持网络唤醒；发送后需回查在线状态。") }
    }

    @ViewBuilder private var content: some View {
        switch resource {
        case .wan: wan
        case .hardware: hardware
        case .capabilities: capabilities
        case .ports: ports
        case .mesh: mesh
        case .dhcp: dhcp
        case .wireless: wireless
        case .guest: guest
        case .upnp: upnp
        case .forward: forward
        case .wirelessSchedule, .maintenance: schedules
        case .behavior: behavior
        case .advanced: advanced
        case .access: access
        case .logs: logs
        case .wake: wake
        case .ddns: ddns
        case .dmz: dmz
        }
    }
    private var wan: some View {
        Group {
            Section("IPv4") {
                RouterFact(title: "连接状态", value: data["network"]["wan_status"]["link_status"].enabled ? "已连接" : "未连接")
                RouterFact(title: "连接方式", value: data["network"]["wan_status"]["proto"].text.uppercased())
                RouterFact(title: "IP 地址", value: data["network"]["wan_status"]["ipaddr"].text)
                RouterFact(title: "网关", value: data["network"]["wan_status"]["gateway"].text)
                RouterFact(title: "主 DNS", value: data["network"]["wan_status"]["pri_dns"].text)
                RouterFact(title: "备用 DNS", value: data["network"]["wan_status"]["snd_dns"].text)
                RouterFact(title: "连接时长", value: RouterDisplay.duration(data["network"]["wan_status"]["up_time"].text))
            }
            Section("IPv6") {
                RouterFact(title: "连接状态", value: data["network"]["wanv6_status"]["link_status"].enabled ? "已连接" : "未连接")
                RouterFact(title: "连接方式", value: data["network"]["wanv6_status"]["proto"].text.uppercased())
                RouterFact(title: "IPv6 地址", value: data["network"]["wanv6_status"]["ip6addr"].text)
                RouterFact(title: "前缀", value: data["network"]["wanv6_status"]["prefix"].text)
                RouterFact(title: "主 DNS", value: data["network"]["wanv6_status"]["pri_dns"].text)
                RouterFact(title: "备用 DNS", value: data["network"]["wanv6_status"]["snd_dns"].text)
            }
        }
    }
    private var hardware: some View {
        Section("路由器") {
            RouterFact(title: "型号", value: data["device_info"]["info"]["device_model"].text)
            RouterFact(title: "硬件版本", value: data["device_info"]["info"]["hw_version"].text)
            RouterFact(title: "固件版本", value: data["device_info"]["info"]["sw_version"].text)
            RouterFact(title: "工作模式", value: store.snapshot?.mode == 0 ? "路由模式" : store.snapshot?.mode == 1 ? "AP（有线中继）" : "无线中继")
            Text("切换工作模式、固件升级与备份恢复请使用路由器原厂管理页。").font(.footnote).foregroundStyle(.secondary)
            Button("重启路由器", role: .destructive) { rebooting = true }.disabled(!store.writable)
        }
    }
    private var capabilities: some View {
        let spec = data["function"]["new_module_spec"]
        return Section("当前固件能力") {
            RouterFact(title: "无线频段", value: "2.4 GHz / 5 GHz")
            RouterFact(title: "IPv6", value: spec["ipv6"].enabled ? "支持" : "未声明")
            RouterFact(title: "易展 Mesh", value: spec["wifison_mesh"].enabled ? "支持" : "未声明")
            RouterFact(title: "离线设备管理", value: spec["support_offline_sta_management"].enabled ? "支持" : "未声明")
            RouterFact(title: "Mesh 节点绑定", value: spec["support_wlan_sta_bind"].enabled ? "支持" : "未声明")
            RouterFact(title: "设备绑定 WAN", value: spec["support_sta_bind_wan"].enabled ? "支持" : "未声明")
            RouterFact(title: "物理端口", value: spec["switch_port_num"].text)
            RouterFact(title: "双 WAN", value: spec["port_custom_sub_func"].array.contains { $0.text == "mwan" } ? "支持" : "未声明")
            RouterFact(title: "IPTV", value: spec["port_custom_sub_func"].array.contains { $0.text == "iptv" } ? "支持" : "未声明")
            RouterFact(title: "端口聚合", value: spec["port_custom_sub_func"].array.contains { $0.text == "lag" } ? "支持" : "未声明")
        }
    }
    private var ports: some View {
        Section("连接与协商速率") {
            ForEach(RouterPort.all(data)) { port in RouterFact(title: "\(port.name) · \(port.role)", value: port.rate) }
        }
    }
    private var mesh: some View {
        Group {
            Section("主路由") { RouterFact(title: "管理地址", value: store.connection?.address ?? ""); RouterFact(title: "状态", value: store.fresh ? "已连接" : "待刷新") }
            Section("子路由") {
                ForEach(data["hyfi"]["connected_ext"].rows, id: \.0) { key, node in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(node["name"].text.isEmpty ? key : node["name"].text).font(.headline)
                        Text(node["mac"].text).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }.alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                }
                if data["hyfi"]["connected_ext"].array.isEmpty { Text("暂无 Mesh 子节点").foregroundStyle(.secondary) }
            }
        }
    }
    private var dhcp: some View {
        Group {
            Section("LAN 与地址分配") {
                RouterFact(title: "LAN 地址", value: store.connection?.address ?? "")
                RouterFact(title: "DHCP", value: data["dhcpd"]["udhcpd"]["enable"].enabled ? "已开启" : "已关闭")
                RouterFact(title: "地址池起点", value: data["dhcpd"]["udhcpd"]["pool_start"].text)
                RouterFact(title: "地址池终点", value: data["dhcpd"]["udhcpd"]["pool_end"].text)
                RouterFact(title: "租期", value: RouterDisplay.duration(data["dhcpd"]["udhcpd"]["lease_time"].text))
            }
            Section("当前租约 · \(data["dhcpd"]["dhcp_clients"].array.count)") {
                ForEach(data["dhcpd"]["dhcp_clients"].rows, id: \.0) { _, lease in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(lease["hostname"].text.isEmpty ? "未命名设备" : lease["hostname"].text)
                        Text("\(lease["ip"].text) · \(lease["mac"].text)").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        Text("剩余租期：\(RouterDisplay.duration(lease["expires"].text))").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }.alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                }
            }
        }
    }
    private var wireless: some View {
        let combined = data["wireless"]["wlan_bs"]["bs_enable"].enabled
        let sections = combined ? ["wlan_bs"] : ["wlan_host_2g", "wlan_host_5g"]
        return Group {
            Section { RouterFact(title: "双频合一", value: combined ? "已开启" : "已关闭") }
            ForEach(sections, id: \.self) { name in
                Section(name == "wlan_bs" ? "主 Wi-Fi" : name == "wlan_host_2g" ? "2.4 GHz" : "5 GHz") {
                    RouterFact(title: "网络名称", value: data["wireless"][name]["ssid"].text)
                    RouterFact(title: "状态", value: data["wireless"][name][name == "wlan_bs" ? "wifi_enable" : "enable"].enabled ? "已开启" : "已关闭")
                    RouterFact(title: "安全", value: data["wireless"][name]["encryption"].enabled ? "密码保护" : "开放网络")
                    if name != "wlan_bs" { RouterFact(title: "信道", value: data["wireless"][name]["channel"].text) }
                    Button("修改网络设置") { editor = .init(kind: .wifi(name), original: data["wireless"][name]) }.disabled(!ready)
                }
            }
        }
    }
    private var guest: some View {
        Section("2.4 GHz 访客网络") {
            RouterFact(title: "网络名称", value: data["guest_network"]["guest_2g"]["ssid"].text)
            RouterFact(title: "状态", value: data["guest_network"]["guest_2g"]["enable"].enabled ? "已开启" : "已关闭")
            RouterFact(title: "访问局域网", value: data["guest_network"]["guest_2g"]["accright"].enabled ? "允许" : "不允许")
            RouterFact(title: "开放时长", value: data["guest_network"]["guest_2g"]["time_limit"].enabled ? data["guest_network"]["guest_2g"]["limit_type"].text == "timeout" ? RouterDisplay.duration(data["guest_network"]["guest_2g"]["duration"].text) : "按计划" : "不限时")
            Button("修改访客网络") { editor = .init(kind: .guest, original: data["guest_network"]["guest_2g"]) }.disabled(!ready)
        }
    }
    private var upnp: some View {
        Group {
            Section {
                RouterFact(title: "UPnP", value: data["upnpd"]["config"]["enable_upnp"].enabled ? "已开启" : "已关闭")
                Button(data["upnpd"]["config"]["enable_upnp"].enabled ? "关闭 UPnP" : "开启 UPnP") {
                    confirming = .init(resource: .upnp, module: "upnpd", section: "config", fields: ["enable_upnp": data["upnpd"]["config"]["enable_upnp"].enabled ? "0" : "1"], original: data["upnpd"]["config"])
                }.disabled(!ready)
            }
            Section("动态映射 · \(data["upnpd"]["upnp_lease"].array.count)") {
                ForEach(data["upnpd"]["upnp_lease"].rows, id: \.0) { _, lease in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(lease["desc"].text.isEmpty ? "自动映射" : lease["desc"].text).font(.headline)
                        Text("\(lease["proto"].text == "6" ? "TCP" : "UDP") \(lease["ext_port"].text) → \(lease["client"].text):\(lease["inner_port"].text)").font(.caption.monospaced()).textSelection(.enabled)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }.alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                }
            }
        }
    }
    private var forward: some View {
        Group {
            Section {
                if store.snapshot?.routerMode == false { Text("虚拟服务器仅在路由模式可用。").foregroundStyle(.orange) }
                Button("新增端口映射") { editor = .init(kind: .forward(nil), original: .null) }.disabled(!ready || store.snapshot?.routerMode != true)
            }
            Section("手动映射 · \(data["firewall"]["redirect"].array.count)") {
                ForEach(data["firewall"]["redirect"].rows, id: \.0) { id, row in
                    VStack(alignment: .leading, spacing: 9) {
                        Text("\(row["proto"].text.uppercased()) · \(row["src_dport_start"].text)–\(row["src_dport_end"].text)").font(.headline)
                        Text("→ \(row["dest_ip"].text):\(row["dest_port"].text)").font(.caption.monospaced()).textSelection(.enabled)
                        HStack(spacing: 24) {
                            Button("编辑") { editor = .init(kind: .forward(id), original: row) }
                            Button("删除", role: .destructive) {
                                confirming = .init(resource: .forward, module: "firewall", section: id, table: "redirect", fields: [:], original: row, kind: .delete, requiresRouterMode: true)
                            }
                        }.buttonStyle(.borderless).disabled(!ready || store.snapshot?.routerMode != true)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }.alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                }
                if data["firewall"]["redirect"].array.isEmpty { Text("暂无手动映射").foregroundStyle(.secondary) }
            }
        }
    }
    private var schedules: some View {
        let reboot = resource == .maintenance, module = reboot ? "reboot_timer" : "time_switch"
        let table = reboot ? "reboot_timer_rule" : "time_switch", general = reboot ? "reboot_timer_status" : "general"
        return Group {
            Section {
                RouterFact(title: "定时总开关", value: data[module][general]["enable"].enabled ? "已开启" : "已关闭")
                RouterFact(title: "路由器时间同步", value: data[module]["clock_success"]["enable"].enabled ? "已同步" : "未同步")
                Button(data[module][general]["enable"].enabled ? "关闭所有计划" : "启用计划") {
                    confirming = .init(resource: resource, module: module, section: general, fields: ["enable": data[module][general]["enable"].enabled ? "0" : "1"], original: data[module][general])
                }.disabled(!ready || !data[module][general]["enable"].enabled && (data[module][table].array.isEmpty || !data[module]["clock_success"]["enable"].enabled))
                Button("新增计划") { editor = .init(kind: .schedule(nil), original: .null) }.disabled(!ready || data[module][table].array.count >= 4)
            }
            Section("计划 · \(data[module][table].array.count) / 4") {
                ForEach(data[module][table].rows, id: \.0) { id, row in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(row["name"].text).font(.headline)
                        Text(reboot ? "\(row["reboot_time"].text) 重启" : "\(row["start_time"].text) 关闭 · \(row["end_time"].text) 恢复")
                            .font(.subheadline.monospacedDigit())
                        Text(zip(RouterScheduleDraft.dayKeys, RouterScheduleDraft.dayLabels).filter { row[$0.0].enabled }.map(\.1).joined(separator: " ")).font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 24) {
                            Button("编辑") { editor = .init(kind: .schedule(id), original: row) }
                            Button("删除", role: .destructive) { confirming = .init(resource: resource, module: module, section: id, table: table, fields: [:], original: row, kind: .delete) }
                        }.buttonStyle(.borderless).disabled(!ready)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }.alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                }
                if data[module][table].array.isEmpty { Text("暂无计划").foregroundStyle(.secondary) }
            }
            Section { Text(reboot ? "计划执行时会重启路由器并暂时中断网络。新增计划后需开启总开关。" : "计划关闭无线网络，不影响有线连接。新增计划后需开启总开关。").font(.footnote).foregroundStyle(.secondary) }
        }
    }
    private var behavior: some View {
        Group {
            if let deviceMAC { Section("当前设备") { RouterFact(title: "MAC 地址", value: deviceMAC) } }
            Section("规则模板") {
                ForEach(data["behave_manage"]["template_rule"].rows, id: \.0) { _, row in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(row["name"].text.isEmpty ? "规则模板" : row["name"].text).font(.headline)
                        RouterFact(title: "状态", value: row["enable"].enabled ? "已开启" : "已关闭")
                        RouterFact(title: "网站访问管理", value: row["web_filter_enable"].enabled ? "已开启" : "已关闭")
                        RouterFact(title: "应用访问管理", value: row["appdist_enable"].enabled ? "已开启" : "已关闭")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }.alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                }
            }
            Section("已分配的设备规则") {
                ForEach(data["behave_manage"]["host_rule"].rows, id: \.0) { _, row in RouterFact(title: row["name"].text, value: row["addr"].text) }
                if data["behave_manage"]["host_rule"].array.isEmpty { Text("暂无设备分配规则").foregroundStyle(.secondary) }
            }
            Section { Text("此处查看固件规则模板及设备分配。复杂上网时段与应用分类规则请在原厂页面管理。").font(.footnote).foregroundStyle(.secondary) }
        }
    }
    private var advanced: some View {
        Group {
            Section("双 WAN") {
                ForEach(data["port_manage"]["mwan"].rows, id: \.0) { key, row in RouterFact(title: key == "mwan_1" ? "WAN 1" : "WAN 2", value: row["enable"].enabled ? "已开启 · 端口 \(row["wan_phy"].text)" : "已关闭") }
            }
            Section("IPTV") {
                ForEach(data["port_manage"]["iptv"].rows, id: \.0) { key, row in RouterFact(title: key == "iptv_1" ? "IPTV 1" : "IPTV 2", value: row["enable"].enabled ? "已开启" : "已关闭") }
            }
            Section("端口聚合") { ForEach(data["port_manage"]["lag"].rows, id: \.0) { _, row in RouterFact(title: "聚合状态", value: row["enable"].enabled ? "已开启" : "已关闭") } }
            Section { Text("高级端口与工作模式修改会中断网络，当前提供只读状态。").font(.footnote).foregroundStyle(.secondary) }
        }
    }
    private var access: some View {
        Group {
            Section { RouterFact(title: "无线接入控制", value: data["wlan_access"]["config"]["enable"].enabled ? "已开启" : "已关闭") }
            Section("接入名单") {
                ForEach(data["wlan_access"]["block_list"].rows, id: \.0) { _, row in RouterFact(title: row["hostname"].text, value: row["mac"].text) }
                if data["wlan_access"]["block_list"].array.isEmpty { Text("暂无名单条目").foregroundStyle(.secondary) }
            }
            Section { Text("接入名单、信号强度与 AP 隔离请在原厂页面配置。设备的互联网访问权限可在设备详情中管理。").font(.footnote).foregroundStyle(.secondary) }
        }
    }
    private var logs: some View {
        Section("系统日志 · \(data["system"]["sys_log"].array.count)") {
            ForEach(data["system"]["sys_log"].rows.reversed(), id: \.0) { _, row in
                VStack(alignment: .leading, spacing: 5) {
                    Text(row["time"].text).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text(row["msg"].text).font(.footnote).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }.alignmentGuide(.listRowSeparatorTrailing) { $0.width }
            }
        }
    }
    private var wake: some View {
        Group {
            Section {
                Button("输入 MAC 地址唤醒") { wakeEditor = true }.disabled(!store.writable)
                Text("需要设备和网卡启用 Wake-on-LAN。请求被接受不代表设备已启动。").font(.footnote).foregroundStyle(.secondary)
            }
            Section("已知有线设备") {
                ForEach((store.snapshot?.devices ?? []).filter { $0.connection == "有线" }) { device in
                    Button { waking = device.mac } label: { RouterFact(title: device.name, value: device.online ? "在线" : "发送唤醒") }.disabled(!store.writable)
                }
            }
        }
    }
    private var ddns: some View {
        Section("DDNS 状态") {
            RouterFact(title: "已登记域名数", value: data["ddns"]["ddns_status"]["domain_num"].text)
            ForEach(Array(data["ddns"]["ddns_status"]["domains"].array.enumerated()), id: \.offset) { _, domain in Text(domain.text).textSelection(.enabled) }
            Text("DDNS 账号与服务商配置请在原厂页面管理。").font(.footnote).foregroundStyle(.secondary)
        }
    }
    private var dmz: some View {
        Section("DMZ") {
            ForEach(data["firewall"]["dmz"].rows, id: \.0) { _, row in
                RouterFact(title: "状态", value: row["enable"].enabled ? "已开启" : "已关闭")
                if row["enable"].enabled { RouterFact(title: "目标 IP", value: row["dest_ip"].text) }
            }
            Text("DMZ 会扩大指定主机的网络暴露面。当前仅查看，修改请使用原厂页面。").font(.footnote).foregroundStyle(.secondary)
        }
    }
}

struct RouterWakeView: View {
    @ObservedObject var store: RouterStore
    @State private var mac = ""
    @State private var error: String?
    @State private var confirming = false
    var body: some View {
        SettingsSheet(title: "远程唤醒", hasChanges: !mac.isEmpty, isBusy: store.busy) {
            Form {
                Section {
                    RouterField(title: "目标设备 MAC 地址") {
                        TextField("02:11:22:33:44:55", text: $mac).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("目标设备 MAC 地址")
                    }
                    Text("目标设备与网卡须支持并开启网络唤醒。").font(.footnote).foregroundStyle(.secondary)
                }
                if let error { Section { Text(error).foregroundStyle(.orange) } }
                Section { Button("发送唤醒请求") { confirming = true }.buttonStyle(HakoActionButtonStyle()).disabled(!store.writable || (try? RouterAddress.mac(mac)) == nil) }
                if let message = store.message { Section { Text(message).font(.footnote) } }
            }
        }
        .alert("发送唤醒请求？", isPresented: $confirming) {
            Button("取消", role: .cancel) { }
            Button("发送") { Task { do { try await store.wake(mac: mac); error = nil } catch { self.error = error.localizedDescription } } }
        } message: { Text(mac) }
    }
}
