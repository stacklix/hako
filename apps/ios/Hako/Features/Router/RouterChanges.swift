import Foundation

enum RouterDeviceChange: Sendable {
    case rename(String), block(Bool), limit(up: Int, down: Int)
    func fields(for device: RouterDevice) throws -> (String, [String: String]) {
        var fields = ["mac": device.mac, "name": device.name == device.mac ? "" : device.name,
                      "is_blocked": device.blocked ? "1" : "0", "up_limit": device.uploadLimit, "down_limit": device.downloadLimit]
        switch self {
        case .rename(let name):
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.utf8.count <= 63, !name.contains(where: { $0.isNewline }) else {
                throw RouterFailure(message: "设备名称不能为空，最多 63 个 UTF-8 字节，且不能包含换行。")
            }
            fields["name"] = name
            return ("set_name", fields)
        case .block(let value):
            fields["is_blocked"] = value ? "1" : "0"
            return ("set_block_flag", fields)
        case .limit(let up, let down):
            guard (0...9_999_999).contains(up), (0...9_999_999).contains(down), device.online else {
                throw RouterFailure(message: "限速值须为 0–9999999 KB/s 的整数，且设备必须在线。")
            }
            fields["up_limit"] = String(up); fields["down_limit"] = String(down)
            return ("set_flux_limit", fields)
        }
    }
    func confirmed(_ next: RouterDevice) -> Bool {
        switch self {
        case .rename(let name): next.name == name.trimmingCharacters(in: .whitespacesAndNewlines)
        case .block(let blocked): next.blocked == blocked
        case .limit(let up, let down): Int(next.uploadLimit) == up && Int(next.downloadLimit) == down
        }
    }
}

struct RouterConfigurationChange: Sendable {
    enum Kind: Sendable { case set, add, delete }
    let resource: RouterResource
    let module: String
    let section: String
    var table: String? = nil
    let fields: [String: String]
    var original: RouterJSON? = nil
    var kind: Kind = .set
    var requiresRouterMode = false

    func payload(current: RouterJSON, snapshot: RouterSnapshot) throws -> [String: Any] {
        guard !requiresRouterMode || snapshot.routerMode else { throw RouterFailure(message: "此功能仅在路由模式下可修改。") }
        if resource == .wireless {
            let combined = current["wireless"]["wlan_bs"]["bs_enable"].enabled
            guard (section == "wlan_bs") == combined else { throw RouterFailure(message: "双频合一设置已改变，请重新打开当前 Wi-Fi 配置。") }
        }
        if resource == .forward, kind != .delete {
            _ = try RouterForwardDraft(ip: fields["dest_ip"] ?? "", externalStart: fields["src_dport_start"] ?? "",
                externalEnd: fields["src_dport_end"] ?? "", internalPort: fields["dest_port"] ?? "", proto: fields["proto"] ?? "", wan: fields["wan_port"] ?? "0")
                .change(current: current, snapshot: snapshot, id: kind == .set ? section : nil)
        }
        if (resource == .maintenance || resource == .wirelessSchedule), kind == .add,
           current[module][table ?? ""].array.count >= 4 { throw RouterFailure(message: "固件最多支持 4 条定时计划，请刷新列表。") }
        let actual = current[module][section].exists ? current[module][section] : current[module][table ?? ""].rows.first(where: { $0.0 == section })?.1 ?? .null
        if let original {
            // Compare the fields being changed; dynamic status/remaining-time fields may change between polls.
            let keys = kind == .delete ? Set(original.object.keys) : Set(fields.keys)
            guard keys.allSatisfy({ actual[$0] == original[$0] }) else {
                throw RouterFailure(message: "远端配置已改变，请重新打开最新配置后再保存。")
            }
        }
        switch kind {
        case .set:
            guard actual.exists else { throw RouterFailure.incompatible }
            return ["method": "set", module: [section: fields]]
        case .add:
            guard let table, !current[module][table].rows.contains(where: { $0.0 == section }) else {
                throw RouterFailure(message: "条目名称已被使用，请刷新后重试。")
            }
            return ["method": "add", module: ["name": section, "table": table, "para": fields]]
        case .delete:
            guard actual.exists else { throw RouterFailure(message: "条目已被删除，请刷新列表。") }
            return ["method": "delete", module: ["name": [section]]]
        }
    }
    func confirmed(_ next: RouterJSON) -> Bool {
        let actual = next[module][section].exists ? next[module][section] : next[module][table ?? ""].rows.first(where: { $0.0 == section })?.1 ?? .null
        if kind == .delete { return !actual.exists }
        return actual.exists && fields.allSatisfy { actual[$0.key].text == $0.value }
    }

    static func wifi(section: String, enabled: Bool, ssid: String, password: String, original: RouterJSON) throws -> Self {
        guard ["wlan_host_2g", "wlan_host_5g", "wlan_bs"].contains(section) else { throw RouterFailure.incompatible }
        try validateWireless(ssid: ssid, password: password)
        let enableKey = section == "wlan_bs" ? "wifi_enable" : "enable"
        return Self(resource: .wireless, module: "wireless", section: section,
                    fields: [enableKey: enabled ? "1" : "0", "ssid": ssid, "key": password, "encryption": password.isEmpty ? "0" : "1"], original: original)
    }
    static func guest(enabled: Bool, ssid: String, password: String, accessLAN: Bool, duration: Int, original: RouterJSON) throws -> Self {
        try validateWireless(ssid: ssid, password: password)
        guard [-1, 0, 3600, 14400, 28800, 86400].contains(duration) else { throw RouterFailure.incompatible }
        var fields = ["enable": enabled ? "1" : "0", "ssid": ssid, "key": password, "encrypt": password.isEmpty ? "0" : "1", "accright": accessLAN ? "1" : "0"]
        if duration >= 0 {
            fields["time_limit"] = duration == 0 ? "0" : "1"
            if duration > 0 { fields["limit_type"] = "timeout"; fields["duration"] = String(duration) }
        }
        return Self(resource: .guest, module: "guest_network", section: "guest_2g", fields: fields, original: original)
    }
    static func validateWireless(ssid: String, password: String) throws {
        guard !ssid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, ssid.utf8.count <= 32, !ssid.contains(where: { $0.isNewline }) else {
            throw RouterFailure(message: "Wi-Fi 名称须为 1–32 个 UTF-8 字节，且不能包含换行。")
        }
        guard password.isEmpty || (8...63).contains(password.utf8.count) && password.utf8.allSatisfy({ (32...126).contains($0) })
                || password.utf8.count == 64 && password.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            throw RouterFailure(message: "Wi-Fi 密码须为 8–63 个 ASCII 字符或 64 位十六进制；留空表示开放网络。")
        }
    }
    static func nextSection(prefix: String, rows: [(String, RouterJSON)]) -> String {
        var index = 1; let names = Set(rows.map(\.0))
        while names.contains("\(prefix)_\(index)") { index += 1 }
        return "\(prefix)_\(index)"
    }
}

struct RouterForwardDraft: Equatable {
    var ip = ""
    var externalStart = ""
    var externalEnd = ""
    var internalPort = ""
    var proto = "tcp"
    var wan = "0"
    func change(current: RouterJSON, snapshot: RouterSnapshot, id: String? = nil) throws -> RouterConfigurationChange {
        guard let ip = RouterAddress.ipv4(ip), RouterAddress.isPrivate(ip), ip & snapshot.mask == snapshot.lanIP & snapshot.mask,
              ip != snapshot.lanIP, ip & ~snapshot.mask != 0, ip & ~snapshot.mask != ~snapshot.mask,
              let start = Int(externalStart), let end = Int(externalEnd.isEmpty ? externalStart : externalEnd), let target = Int(internalPort),
              (1...65535).contains(start), (start...65535).contains(end), (1...65535).contains(target),
              ["tcp", "udp", "all"].contains(proto), ["0", "1", "2"].contains(wan) else {
            throw RouterFailure(message: "请填写同网段的设备 IP、有效端口（1–65535）与协议。")
        }
        let rows = current["firewall"]["redirect"].rows
        guard !rows.contains(where: { key, row in
            key != id && (row["proto"].text == proto || row["proto"].text == "all" || proto == "all")
                && start <= (Int(row["src_dport_end"].text) ?? 0) && end >= (Int(row["src_dport_start"].text) ?? 0)
                && (row["wan_port"].text == wan || row["wan_port"].text == "0" || wan == "0")
        }) else { throw RouterFailure(message: "外部端口与已有映射重叠，请选择其他端口。") }
        return RouterConfigurationChange(resource: .forward, module: "firewall", section: id ?? RouterConfigurationChange.nextSection(prefix: "redirect", rows: rows), table: "redirect",
                fields: ["dest_ip": self.ip, "dest_port": String(target), "src_dport_start": String(start), "src_dport_end": String(end), "proto": proto, "wan_port": wan],
                original: id.flatMap { key in rows.first { $0.0 == key }?.1 }, kind: id == nil ? .add : .set, requiresRouterMode: true)
    }
}

struct RouterScheduleDraft: Equatable {
    var name = ""
    var start = "00:30"
    var end = "07:00"
    var days = Array(repeating: true, count: 7)
    static let dayKeys = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
    static let dayLabels = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
    static func validTime(_ text: String) -> Bool {
        let parts = text.split(separator: ":")
        return parts.count == 2 && parts.allSatisfy { $0.count == 2 && $0.utf8.allSatisfy { (48...57).contains($0) } }
            && (0...23).contains(Int(parts[0]) ?? -1) && (0...59).contains(Int(parts[1]) ?? -1)
    }
    func change(resource: RouterResource, current: RouterJSON, id: String? = nil) throws -> RouterConfigurationChange {
        let reboot = resource == .maintenance
        guard reboot || resource == .wirelessSchedule, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf8.count <= 32, days.count == 7, days.contains(true), Self.validTime(start), reboot || Self.validTime(end) && start != end else {
            throw RouterFailure(message: "请填写计划名称、有效时间（HH:mm）及至少一个重复日期；关闭与恢复时间不能相同。")
        }
        let module = reboot ? "reboot_timer" : "time_switch", table = reboot ? "reboot_timer_rule" : "time_switch"
        let rows = current[module][table].rows
        guard id != nil || rows.count < 4 else { throw RouterFailure(message: "固件最多支持 4 条定时计划。") }
        var fields = Dictionary(uniqueKeysWithValues: zip(Self.dayKeys, days.map { $0 ? "1" : "0" }))
        fields["name"] = name
        if reboot { fields["reboot_time"] = start }
        else { fields["enable"] = "1"; fields["start_time"] = start; fields["end_time"] = end }
        return RouterConfigurationChange(resource: resource, module: module, section: id ?? RouterConfigurationChange.nextSection(prefix: table, rows: rows), table: table,
            fields: fields, original: id.flatMap { key in rows.first { $0.0 == key }?.1 }, kind: id == nil ? .add : .set)
    }
}
