import SwiftUI

struct RouterDeviceRow: View {
    let device: RouterDevice
    var bound = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 11) {
                Image(systemName: device.connection == "有线" ? "desktopcomputer" : "wifi")
                    .font(.title3).frame(width: 36, height: 38).foregroundStyle(RouterStyle.muted)
                    .background(RouterStyle.fill, in: RoundedRectangle(cornerRadius: 11)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(device.name).font(.subheadline.weight(.medium)).multilineTextAlignment(.leading)
                    Text(device.ip.isEmpty ? device.mac : device.ip).font(.caption.monospaced()).foregroundStyle(RouterStyle.muted)
                    HStack(spacing: 5) {
                        Text(device.connection).font(.caption2).foregroundStyle(RouterStyle.muted)
                        if bound { RouterBadge(text: "已绑定") }
                        if device.isCurrent { RouterBadge(text: "本机", tint: .blue) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if device.online && !device.blocked {
                    VStack(alignment: .trailing, spacing: 5) {
                        Text("↓ \(RouterDisplay.speed(device.download))")
                        Text("↑ \(RouterDisplay.speed(device.upload))")
                    }.font(.caption2.monospacedDigit()).foregroundStyle(RouterStyle.muted)
                } else { Text(device.blocked ? "禁止上网" : "已离线").font(.caption2).foregroundStyle(RouterStyle.muted) }
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(RouterStyle.muted).accessibilityHidden(true)
            }.padding(14).contentShape(Rectangle())
        }.buttonStyle(.plain).overlay(alignment: .bottom) { Divider().padding(.horizontal, 14) }
    }
}

struct RouterDevicesContent: View {
    @ObservedObject var store: RouterStore
    let open: (RouterScreen) -> Void
    @State private var filter = 0
    @State private var search = ""
    private var devices: [RouterDevice] {
        let all = filter == 0 ? store.snapshot?.onlineDevices : filter == 1 ? store.snapshot?.offlineDevices : store.snapshot?.blockedDevices
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ":", with: "-")
        return (all ?? []).filter { query.isEmpty || [$0.name, $0.ip, $0.mac, $0.ssid].contains { $0.localizedCaseInsensitiveContains(query) } }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(RouterStyle.muted)
                TextField("名称、IP 或 MAC", text: $search).accessibilityLabel("搜索设备名称、IP 或 MAC")
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }.font(.subheadline).padding(12).background(RouterStyle.panel, in: RoundedRectangle(cornerRadius: 12))
            Picker("设备状态", selection: $filter) {
                Text("在线 \(store.snapshot?.onlineDevices.count ?? 0)").tag(0)
                Text("离线 \(store.snapshot?.offlineDevices.count ?? 0)").tag(1)
                Text("禁用 \(store.snapshot?.blockedDevices.count ?? 0)").tag(2)
            }.pickerStyle(.segmented)
            HStack { Text("接入设备").font(.headline); Spacer(); Button("绑定管理") { open(.bindings) }.font(.footnote) }
            if let error = store.deviceSpeedError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            RouterPanel {
                ForEach(devices) { device in
                    RouterDeviceRow(device: device, bound: store.snapshot?.bindings.contains { $0.mac == device.mac } == true) { open(.device(device.mac)) }
                }
                if devices.isEmpty {
                    Text(search.isEmpty ? "暂无设备" : "没有匹配的设备").font(.subheadline).foregroundStyle(RouterStyle.muted).padding(30)
                }
            }
            Text("速率是设备当前上下行速度，不表示历史流量。").font(.caption).foregroundStyle(RouterStyle.muted)
        }.disabled(store.busy)
    }
}

struct RouterBindingsView: View {
    @ObservedObject var store: RouterStore
    @State private var search = ""
    @State private var editor: RouterBindingSelection?
    @State private var deleting: RouterBinding?
    @State private var choosing = false
    @State private var chosen: RouterBindingSelection?
    private var bindings: [RouterBinding] {
        let query = search.replacingOccurrences(of: ":", with: "-")
        return (store.snapshot?.bindings ?? []).filter { query.isEmpty || [$0.name, $0.ip, $0.mac].contains { $0.localizedCaseInsensitiveContains(query) } }
    }
    var body: some View {
        SettingsSheet(title: "IP/MAC 绑定", isBusy: store.busy) {
            List {
                Section {
                    if store.snapshot?.routerMode == false { Text("AP 或无线中继模式下，固件禁用 IP/MAC 绑定。").font(.footnote).foregroundStyle(.orange) }
                    Button("从接入设备创建绑定") { choosing = true }.disabled(!store.bindingsWritable)
                    Button("手动新增绑定") { editor = .init(draft: .init()) }.disabled(!store.bindingsWritable)
                }
                Section("绑定记录 · \(store.snapshot?.bindings.count ?? 0)") {
                    ForEach(bindings) { binding in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(binding.name.isEmpty ? binding.ip : binding.name).font(.headline)
                            Text(binding.ip).font(.subheadline.monospaced()).textSelection(.enabled)
                            Text(binding.mac).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            HStack(spacing: 24) {
                                Button("编辑") { editor = .init(original: binding, draft: .init(ip: binding.ip, mac: binding.mac, name: binding.name)) }
                                Button("删除", role: .destructive) { deleting = binding }
                            }.buttonStyle(.borderless).disabled(!store.bindingsWritable)
                        }.padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading)
                            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                            .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                    }
                    if bindings.isEmpty { Text("暂无匹配的绑定").foregroundStyle(.secondary) }
                }
                Section {
                    Text("绑定固定 IP 与 MAC 的对应关系；分配地址与租约生效方式以固件为准。使用随机 Wi-Fi 地址的设备需保持此网络下的 MAC 稳定。").font(.footnote).foregroundStyle(.secondary)
                    if let message = store.message { Text(message).font(.footnote).foregroundStyle(.orange) }
                    Button("刷新并核对绑定") { Task { await store.refresh() } }.disabled(store.busy)
                }
            }.searchable(text: $search, prompt: "名称、IP 或 MAC")
        }
        .task { await store.refresh() }
        .sheet(item: $editor) { value in RouterBindingEditor(store: store, original: value.original, initial: value.draft) }
        .sheet(isPresented: $choosing, onDismiss: {
            if let chosen { editor = chosen; self.chosen = nil }
        }) {
            SettingsSheet(title: "选择接入设备", isBusy: store.busy) {
                List {
                    ForEach(store.snapshot?.onlineDevices ?? []) { device in
                        Button {
                            choosing = false
                            let binding = store.snapshot?.bindings.first { $0.mac == device.mac }
                            chosen = .init(original: binding, draft: .init(ip: binding?.ip ?? device.ip, mac: device.mac, name: binding?.name ?? device.name))
                        } label: { RouterFact(title: device.name, value: device.ip) }
                    }
                }
            }
        }
        .alert("删除此绑定？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { binding in
            Button("取消", role: .cancel) { deleting = nil }
            Button("删除绑定", role: .destructive) {
                Task { do { try await store.remove(binding) } catch { store.message = error.localizedDescription }; deleting = nil }
            }
        } message: { binding in Text("\(binding.ip)\n\(binding.mac)\n删除后会回查路由器上的实际状态。") }
    }
}

struct RouterBindingSelection: Identifiable {
    let id = UUID()
    var original: RouterBinding? = nil
    let draft: RouterBindingDraft
}

struct RouterDeviceView: View {
    @ObservedObject var store: RouterStore
    let mac: String
    @State private var editor: RouterDeviceEditorKind?
    @State private var binding: RouterBindingSelection?
    @State private var rules = false
    @State private var blocking = false
    private var device: RouterDevice? { store.snapshot?.devices.first { $0.mac == mac } }
    var body: some View {
        SettingsSheet(title: "设备详情", isBusy: store.busy) {
            Form {
                if let device {
                    Section {
                        Label(device.name, systemImage: device.connection == "有线" ? "desktopcomputer" : "wifi").font(.headline)
                        RouterFact(title: "状态", value: device.blocked ? "禁止上网" : device.online ? "在线" : "离线")
                        RouterFact(title: "IP 地址", value: device.ip)
                        RouterFact(title: "MAC 地址", value: device.mac)
                        RouterFact(title: "IPv6", value: device.ipv6)
                        RouterFact(title: "接入方式", value: device.connection)
                        if !device.ssid.isEmpty { RouterFact(title: "Wi-Fi 名称", value: device.ssid) }
                        if !device.rssi.isEmpty && device.connection != "有线" { RouterFact(title: "信号", value: "\(device.rssi) dBm") }
                        if device.online { RouterFact(title: "连接时长", value: RouterDisplay.duration(device.connectedSeconds)) }
                    }
                    if device.online && !device.blocked {
                        Section("当前速率") {
                            RouterFact(title: "下载", value: RouterDisplay.speed(device.download))
                            RouterFact(title: "上传", value: RouterDisplay.speed(device.upload))
                        }
                    }
                    Section("管理") {
                        Button("修改名称") { editor = .rename }.disabled(!store.writable)
                        Button("IP/MAC 绑定") {
                            let existing = store.snapshot?.bindings.first { $0.mac == mac }
                            binding = .init(original: existing, draft: .init(ip: existing?.ip ?? device.ip, mac: mac, name: existing?.name ?? device.name))
                        }.disabled(!store.bindingsWritable)
                        Button("设备限速") { editor = .limit }.disabled(!store.writable || !device.online)
                        Button("上网规则") { rules = true }.disabled(store.busy)
                        Button(device.blocked ? "允许设备上网" : "禁止设备上网", role: device.blocked ? nil : .destructive) { blocking = true }.disabled(!store.writable)
                    }
                } else { Section { Text("设备已不在当前列表，请刷新核对。") } }
                Section {
                    if let message = store.message { Text(message).font(.footnote).foregroundStyle(.orange) }
                    Button("刷新设备详情") { Task { await store.refresh() } }.disabled(store.busy)
                }
            }
        }
        .sheet(item: $editor) { kind in if let device { RouterDeviceEditor(store: store, device: device, kind: kind) } }
        .sheet(item: $binding) { value in RouterBindingEditor(store: store, original: value.original, initial: value.draft) }
        .sheet(isPresented: $rules) { RouterResourceView(store: store, resource: .behavior, deviceMAC: mac) }
        .alert(device?.blocked == true ? "允许设备上网？" : "禁止设备上网？", isPresented: $blocking) {
            Button("取消", role: .cancel) { }
            Button("确认", role: device?.blocked == true ? nil : .destructive) {
                if let device { Task { do { try await store.changeDevice(device, change: .block(!device.blocked)) } catch { store.message = error.localizedDescription } } }
            }
        } message: {
            Text(device?.isCurrent == true ? "这是当前管理设备。禁止上网可能中断当前连接，请确认后操作。" : "操作会改变此设备的互联网访问权限，并回查实际结果。")
        }
    }
}

enum RouterDeviceEditorKind: String, Identifiable { case rename, limit; var id: Self { self } }
struct RouterDeviceEditor: View {
    @ObservedObject var store: RouterStore
    let device: RouterDevice
    let kind: RouterDeviceEditorKind
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var up = "0"
    @State private var down = "0"
    @State private var error: String?
    @State private var confirming = false
    private var changed: Bool { kind == .rename ? name != device.name : up != device.uploadLimit || down != device.downloadLimit }
    var body: some View {
        SettingsSheet(title: kind == .rename ? "修改名称" : "设备限速", hasChanges: changed, isBusy: store.busy,
                      saveEnabled: changed && store.writable, onSave: { confirming = true }) {
            Form {
                Section(device.name) {
                    if kind == .rename {
                        RouterField(title: "设备名称") { TextField("设备名称", text: $name).accessibilityLabel("设备名称") }
                    } else {
                        RouterField(title: "上传上限（KB/s）") { TextField("0 表示不限速", text: $up).keyboardType(.numberPad).accessibilityLabel("上传上限 KB/s") }
                        RouterField(title: "下载上限（KB/s）") { TextField("0 表示不限速", text: $down).keyboardType(.numberPad).accessibilityLabel("下载上限 KB/s") }
                        Text("0 表示不限速。固件使用 KB/s；开启硬件加速时，需先在路由器中核对限速条件。").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.orange) } }
                Section {
                    Button("确认保存") { confirming = true }.buttonStyle(HakoActionButtonStyle()).disabled(!changed || !store.writable)
                    if !store.writable { Button("刷新并核对状态") { Task { await store.refresh() } }.disabled(store.busy) }
                }
            }
        }
        .onAppear { name = device.name; up = device.uploadLimit; down = device.downloadLimit }
        .alert("保存设备设置？", isPresented: $confirming) {
            Button("取消", role: .cancel) { }
            Button("保存") {
                Task {
                    do {
                        let change: RouterDeviceChange
                        if kind == .rename { change = .rename(name) }
                        else {
                            guard let up = Int(up), let down = Int(down) else { throw RouterFailure(message: "请输入整数限速值。") }
                            change = .limit(up: up, down: down)
                        }
                        try await store.changeDevice(device, change: change); dismiss()
                    } catch { self.error = error.localizedDescription }
                }
            }
        } message: { Text("将修改路由器上的设备设置，并回查实际结果。") }
    }
}
