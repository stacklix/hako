import SwiftUI

struct RouterConfigurationEditorSelection: Identifiable {
    enum Kind { case wifi(String), guest, forward(String?), schedule(String?) }
    let id = UUID()
    let kind: Kind
    let original: RouterJSON
}

struct RouterConfigurationEditor: View {
    @ObservedObject var store: RouterStore
    let resource: RouterResource
    let selection: RouterConfigurationEditorSelection
    @Environment(\.dismiss) private var dismiss
    @State private var enabled = false
    @State private var ssid = ""
    @State private var password = ""
    @State private var accessLAN = false
    @State private var duration = -1
    @State private var forward = RouterForwardDraft()
    @State private var schedule = RouterScheduleDraft()
    @State private var baseline: [String: String] = [:]
    @State private var error: String?
    @State private var confirming = false
    private var changes: [String: String] {
        switch selection.kind {
        case .wifi: ["enabled": String(enabled), "ssid": ssid, "password": password]
        case .guest: ["enabled": String(enabled), "ssid": ssid, "password": password, "accessLAN": String(accessLAN), "duration": String(duration)]
        case .forward: ["ip": forward.ip, "start": forward.externalStart, "end": forward.externalEnd, "internal": forward.internalPort, "protocol": forward.proto, "wan": forward.wan]
        case .schedule: ["name": schedule.name, "start": schedule.start, "end": schedule.end, "days": schedule.days.map { $0 ? "1" : "0" }.joined()]
        }
    }
    private var dirty: Bool { changes != baseline }
    private var title: String {
        switch selection.kind { case .wifi: "修改主 Wi-Fi"; case .guest: "访客网络设置"; case .forward(let id): id == nil ? "新增端口映射" : "编辑端口映射"; case .schedule(let id): id == nil ? "新增定时计划" : "编辑定时计划" }
    }
    private var needsNewRecord: Bool {
        switch selection.kind { case .forward(let id), .schedule(let id): id == nil; default: false }
    }
    var body: some View {
        SettingsSheet(title: title, hasChanges: dirty, isBusy: store.busy,
                      saveEnabled: store.canEdit(resource) && (dirty || needsNewRecord), onSave: prepare) {
            Form {
                fields
                if let error { Section { Text(error).font(.footnote).foregroundStyle(.orange) } }
                Section {
                    Button("保存配置") { prepare() }.buttonStyle(HakoActionButtonStyle()).disabled(!store.canEdit(resource) || !dirty && !needsNewRecord)
                    if !store.canEdit(resource) {
                        Button("刷新并核对状态") { Task { await store.refresh([resource]) } }.disabled(store.busy)
                        Text("刷新后如原配置已改变，请保留草稿并重新打开最新配置。").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }.textInputAutocapitalization(.never).autocorrectionDisabled()
        }
        .onAppear { populate() }
        .alert("保存此配置？", isPresented: $confirming) {
            Button("取消", role: .cancel) { }
            Button("确认保存") {
                Task {
                    do { try await store.apply(makeChange()); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
            }
        } message: {
            Text(resource == .wireless || resource == .guest ? "将修改无线网络设置，当前连接可能暂时中断。\(password.isEmpty ? "密码为空，网络将不受密码保护。" : "")保存后会回查状态。" : resource == .maintenance ? "将保存自动重启计划。计划执行时网络将暂时中断；总开关需在计划列表中单独开启。" : "将修改路由器配置，并回查实际结果。")
        }
    }
    @ViewBuilder private var fields: some View {
        switch selection.kind {
        case .wifi, .guest:
            Section {
                Toggle("启用网络", isOn: $enabled)
                RouterField(title: "Wi-Fi 名称") { TextField("网络名称", text: $ssid).accessibilityLabel("Wi-Fi 名称") }
                RouterField(title: "Wi-Fi 密码") { SecureField("留空表示开放网络", text: $password).accessibilityLabel("Wi-Fi 密码") }
            }
            if case .guest = selection.kind {
                Section {
                    Toggle("允许访问局域网", isOn: $accessLAN)
                    Picker("开放时长", selection: $duration) {
                        Text("保留现有时间设置").tag(-1)
                        Text("不限时").tag(0)
                        Text("1 小时").tag(3600)
                        Text("4 小时").tag(14400)
                        Text("8 小时").tag(28800)
                        Text("24 小时").tag(86400)
                    }
                    Text("此固件提供 2.4 GHz 访客网络。修改开放时长不会自动改变原有的计划条目。").font(.footnote).foregroundStyle(.secondary)
                }
            }
        case .forward:
            Section {
                RouterField(title: "目标设备 IP") { TextField("192.168.0.100", text: $forward.ip).keyboardType(.decimalPad).accessibilityLabel("目标设备 IP") }
                RouterField(title: "外部起始端口") { TextField("1–65535", text: $forward.externalStart).keyboardType(.numberPad).accessibilityLabel("外部起始端口") }
                RouterField(title: "外部结束端口（可选）") { TextField("留空使用起始端口", text: $forward.externalEnd).keyboardType(.numberPad).accessibilityLabel("外部结束端口") }
                RouterField(title: "内部端口") { TextField("1–65535", text: $forward.internalPort).keyboardType(.numberPad).accessibilityLabel("内部端口") }
                Picker("协议", selection: $forward.proto) { Text("TCP").tag("tcp"); Text("UDP").tag("udp"); Text("TCP + UDP").tag("all") }
                Picker("生效接口", selection: $forward.wan) { Text("全部 WAN").tag("0"); Text("WAN 1").tag("1"); Text("WAN 2").tag("2") }
                Text("端口转发会允许外部网络访问指定的局域网服务，请核对地址、端口与目标服务的访问保护。").font(.footnote).foregroundStyle(.secondary)
            }
        case .schedule:
            Section {
                RouterField(title: "计划名称") { TextField("例如：夜间休息", text: $schedule.name).accessibilityLabel("计划名称") }
                RouterField(title: resource == .maintenance ? "重启时间" : "关闭 Wi-Fi 时间") {
                    DatePicker("执行时间", selection: timeBinding(start: true), displayedComponents: .hourAndMinute).labelsHidden().accessibilityLabel(resource == .maintenance ? "重启时间" : "关闭 Wi-Fi 时间")
                }
                if resource != .maintenance {
                    RouterField(title: "恢复 Wi-Fi 时间") { DatePicker("恢复 Wi-Fi 时间", selection: timeBinding(start: false), displayedComponents: .hourAndMinute).labelsHidden().accessibilityLabel("恢复 Wi-Fi 时间") }
                }
            }
            Section("重复日期") {
                ForEach(0..<7) { index in Toggle(RouterScheduleDraft.dayLabels[index], isOn: $schedule.days[index]) }
            }
            Section { Text("按路由器本地时间执行，需时间同步成功。新增计划后，在计划列表单独开启总开关。").font(.footnote).foregroundStyle(.secondary) }
        }
    }
    private func populate() {
        let row = selection.original
        switch selection.kind {
        case .wifi(let section):
            enabled = row[section == "wlan_bs" ? "wifi_enable" : "enable"].enabled; ssid = row["ssid"].text; password = row["key"].text
        case .guest:
            enabled = row["enable"].enabled; ssid = row["ssid"].text; password = row["key"].text; accessLAN = row["accright"].enabled; duration = -1
        case .forward:
            forward = .init(ip: row["dest_ip"].text, externalStart: row["src_dport_start"].text, externalEnd: row["src_dport_end"].text,
                            internalPort: row["dest_port"].text, proto: row["proto"].text.isEmpty ? "tcp" : row["proto"].text, wan: row["wan_port"].text.isEmpty ? "0" : row["wan_port"].text)
        case .schedule(let id):
            if id != nil {
                schedule = .init(name: row["name"].text, start: row[resource == .maintenance ? "reboot_time" : "start_time"].text,
                                 end: resource == .maintenance ? "07:00" : row["end_time"].text, days: RouterScheduleDraft.dayKeys.map { row[$0].enabled })
            }
        }
        baseline = changes
    }
    private func timeBinding(start: Bool) -> Binding<Date> {
        Binding(get: {
            let parts = (start ? schedule.start : schedule.end).split(separator: ":").compactMap { Int($0) }
            return Calendar.current.date(bySettingHour: parts.first ?? 0, minute: parts.count > 1 ? parts[1] : 0, second: 0, of: .now) ?? .now
        }, set: { value in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: value)
            let text = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
            if start { schedule.start = text } else { schedule.end = text }
        })
    }
    private func prepare() {
        do { _ = try makeChange(); error = nil; confirming = true }
        catch { self.error = error.localizedDescription }
    }
    private func makeChange() throws -> RouterConfigurationChange {
        guard let snapshot = store.snapshot else { throw RouterFailure(message: "请先读取路由器状态。") }
        switch selection.kind {
        case .wifi(let section): return try .wifi(section: section, enabled: enabled, ssid: ssid, password: password, original: selection.original)
        case .guest: return try .guest(enabled: enabled, ssid: ssid, password: password, accessLAN: accessLAN, duration: duration, original: selection.original)
        case .forward(let id):
            var result = try forward.change(current: store.value(resource), snapshot: snapshot, id: id)
            if id != nil { result.original = selection.original }
            return result
        case .schedule(let id):
            var result = try schedule.change(resource: resource, current: store.value(resource), id: id)
            if id != nil { result.original = selection.original }
            return result
        }
    }
}
