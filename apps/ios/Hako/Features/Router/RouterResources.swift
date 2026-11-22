import Foundation

indirect enum RouterJSON: Equatable, Sendable {
    case object([String: RouterJSON]), array([RouterJSON]), string(String), number(Double), bool(Bool), null
    init(_ value: Any) throws {
        switch value {
        case let value as String: self = .string(value)
        case let value as [String: Any]: self = .object(try value.mapValues(Self.init))
        case let value as [Any]: self = .array(try value.map(Self.init))
        case let value as NSNumber: self = .number(value.doubleValue)
        case is NSNull: self = .null
        default: throw RouterFailure.incompatible
        }
    }
    subscript(_ key: String) -> Self { if case .object(let values) = self { return values[key] ?? .null }; return .null }
    var text: String {
        switch self {
        case .string(let value): return value.removingPercentEncoding ?? value
        case .number(let value): return value.isFinite && value.rounded() == value ? String(format: "%.0f", value) : String(value)
        case .bool(let value): return value ? "1" : "0"
        default: return ""
        }
    }
    var enabled: Bool { ["1", "on", "true"].contains(text) }
    var array: [Self] { if case .array(let values) = self { return values }; return [] }
    var object: [String: Self] { if case .object(let values) = self { return values }; return [:] }
    var exists: Bool { self != .null }
    var raw: Any {
        switch self {
        case .object(let value): return value.mapValues(\.raw)
        case .array(let value): return value.map(\.raw)
        case .string: return text
        case .number(let value): return value
        case .bool(let value): return value
        case .null: return NSNull()
        }
    }
    var rows: [(String, Self)] { array.flatMap { $0.object.sorted { $0.key < $1.key }.map { ($0.key, $0.value) } } }
}

enum RouterResource: String, CaseIterable, Identifiable, Sendable {
    case wan, hardware, capabilities, wireless, guest, dhcp, ports, mesh, behavior, upnp, forward, ddns, dmz, wirelessSchedule, access, advanced, maintenance, logs, wake
    var id: Self { self }
    var title: String {
        switch self {
        case .wan: "互联网与 IPv6"
        case .hardware: "系统信息"
        case .capabilities: "路由器能力"
        case .wireless: "主 Wi-Fi"
        case .guest: "访客网络"
        case .dhcp: "DHCP 与 LAN"
        case .ports: "端口状态"
        case .mesh: "易展 Mesh"
        case .behavior: "上网规则"
        case .upnp: "UPnP 映射"
        case .forward: "端口转发"
        case .ddns: "动态域名 DDNS"
        case .dmz: "DMZ 主机"
        case .wirelessSchedule: "无线定时"
        case .access: "无线接入控制"
        case .advanced: "双 WAN / IPTV / 聚合"
        case .maintenance: "自动清理"
        case .logs: "系统日志"
        case .wake: "远程唤醒"
        }
    }
    var query: [String: Any] {
        switch self {
        case .wan: ["network": ["name": ["wan_status", "wanv6_status"]]]
        case .hardware: ["device_info": ["name": "info"]]
        case .capabilities: ["function": ["name": "new_module_spec"]]
        case .wireless: ["wireless": ["name": ["wlan_host_2g", "wlan_host_5g", "wlan_bs"]]]
        case .guest: ["guest_network": ["name": "guest_2g"]]
        case .dhcp: ["dhcpd": ["name": "udhcpd", "table": "dhcp_clients"]]
        case .ports: ["port_manage": ["table": "dev_info"]]
        case .mesh: ["hyfi": ["table": "connected_ext"]]
        case .behavior: ["behave_manage": ["name": "capability", "table": ["template_rule", "host_rule"]]]
        case .upnp: ["upnpd": ["name": "config", "table": "upnp_lease"]]
        case .forward: ["firewall": ["table": "redirect"]]
        case .ddns: ["ddns": ["name": "ddns_status"]]
        case .dmz: ["firewall": ["table": "dmz"]]
        case .wirelessSchedule: ["time_switch": ["name": ["general", "clock_success"], "table": "time_switch"]]
        case .access: ["wlan_access": ["name": "config", "table": "block_list"]]
        case .advanced: ["port_manage": ["table": ["mwan", "iptv", "lag"]]]
        case .maintenance: ["reboot_timer": ["name": ["reboot_timer_status", "clock_success"], "table": "reboot_timer_rule"]]
        case .logs: ["system": ["table": "sys_log"]]
        case .wake: ["wake_on_lan": ["get_device_list": NSNull()]]
        }
    }
    var method: String { self == .wake ? "do" : "get" }
    func validate(_ data: RouterJSON) throws {
        let expected: RouterJSON
        switch self {
        case .wan: expected = data["network"]["wan_status"]
        case .hardware: expected = data["device_info"]["info"]
        case .capabilities: expected = data["function"]["new_module_spec"]
        case .wireless: expected = data["wireless"]["wlan_host_2g"]
        case .guest: expected = data["guest_network"]["guest_2g"]
        case .dhcp: expected = data["dhcpd"]["udhcpd"]
        case .ports: expected = data["port_manage"]["dev_info"]
        case .mesh: expected = data["hyfi"]["connected_ext"]
        case .behavior: expected = data["behave_manage"]["capability"]
        case .upnp: expected = data["upnpd"]["config"]
        case .forward: expected = data["firewall"]["redirect"]
        case .ddns: expected = data["ddns"]["ddns_status"]
        case .dmz: expected = data["firewall"]["dmz"]
        case .wirelessSchedule: expected = data["time_switch"]["general"]
        case .access: expected = data["wlan_access"]["config"]
        case .advanced: expected = data["port_manage"]["mwan"]
        case .maintenance: expected = data["reboot_timer"]["reboot_timer_status"]
        case .logs: expected = data["system"]["sys_log"]
        case .wake: expected = data["wake_on_lan"]["device_list"]
        }
        guard expected.exists else { throw RouterFailure.incompatible }
    }
}

struct RouterPort: Identifiable, Sendable {
    let id: String
    let name: String
    let role: String
    let online: Bool
    let rate: String
    init(_ data: RouterJSON, device: String) {
        id = device + ":" + data["phy"].text
        let physical = (Int(data["phy"].text) ?? 0) + 1
        name = data["type"].text == "SFP" ? "光口" : "端口 \(physical)"
        role = data["role"].text.uppercased(); online = data["status"].enabled
        let rate = data["nego_rate"].text
        self.rate = !online ? "未连接" : rate == "1000MF" ? "1 Gbps · 全双工" : rate == "2500MF" ? "2.5 Gbps · 全双工" : rate == "100MF" ? "100 Mbps · 全双工" : rate
    }
    static func all(_ data: RouterJSON) -> [Self] {
        data["port_manage"]["dev_info"].array.flatMap { device in
            device["phy_info"].array.map { Self($0, device: device["mac"].text) }
        }
    }
}

enum RouterDisplay {
    static func speed(_ bytes: Double) -> String {
        let value = bytes.isFinite ? max(0, bytes) : 0
        return value >= 1_048_576 ? String(format: "%.1f MB/s", value / 1_048_576) : String(format: "%.1f KB/s", value / 1024)
    }
    static func duration(_ seconds: String) -> String {
        guard let seconds = Int(seconds), seconds >= 0 else { return "未提供" }
        return seconds >= 86400 ? "\(seconds / 86400) 天 \(seconds % 86400 / 3600) 小时" : seconds >= 3600 ? "\(seconds / 3600) 小时 \(seconds % 3600 / 60) 分钟" : "\(seconds / 60) 分钟"
    }
}
