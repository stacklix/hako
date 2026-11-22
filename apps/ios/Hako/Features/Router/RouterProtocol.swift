import Foundation

struct RouterFailure: LocalizedError, Sendable {
    let message: String
    var outcomeUnknown = false
    var errorDescription: String? { message }
    static let incompatible = Self(message: "路由器返回的数据格式不受支持，请核对型号和固件。")
}

struct RouterConnection: Codable, Equatable, Sendable {
    var address = "192.168.0.1"
    var password = ""

    func normalized() throws -> Self {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ip = RouterAddress.ipv4(address), RouterAddress.isPrivate(ip), !password.isEmpty,
              password.utf16.count <= 64, !password.contains(where: { $0.isNewline }) else {
            throw RouterFailure(message: "请填写局域网 IPv4 地址及有效的管理员密码。")
        }
        return Self(address: address, password: password)
    }
}

enum RouterRoute: String, CaseIterable, Sendable {
    case direct, sora
    var title: String { self == .direct ? "局域网直连" : "Sora 代理" }
}

enum RouterAddress {
    static func ipv4(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var result: UInt32 = 0
        for part in parts {
            guard !part.isEmpty, part.count == 1 || part.first != "0",
                  part.utf8.allSatisfy({ (48...57).contains($0) }), let byte = UInt8(part) else { return nil }
            result = (result << 8) | UInt32(byte)
        }
        return result
    }

    static func isPrivate(_ ip: UInt32) -> Bool {
        ip >> 24 == 10 || ip >> 20 == 0xAC1 || ip >> 16 == 0xC0A8
    }

    static func mac(_ text: String) throws -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ":", with: "-").uppercased()
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 6, parts.allSatisfy({ $0.count == 2 && $0.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0)
        }) }), let first = UInt8(parts[0], radix: 16), first & 1 == 0,
              value != "00-00-00-00-00-00" else {
            throw RouterFailure(message: "请输入有效的单播 MAC 地址，例如 02:11:22:33:44:55。")
        }
        return value
    }
}

struct RouterDevice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let ip: String
    let mac: String
    let connection: String
    let upload: Double
    let download: Double
    var online = true
    var blocked = false
    var isCurrent = false
    var ipv6 = ""
    var ssid = ""
    var rssi = ""
    var connectedSeconds = ""
    var uploadLimit = "0"
    var downloadLimit = "0"
}

struct RouterBinding: Identifiable, Equatable, Sendable {
    let id: String
    let ip: String
    let mac: String
    let name: String
}

struct RouterBindingDraft: Equatable, Sendable {
    var ip = ""
    var mac = ""
    var name = ""

    func validated(in snapshot: RouterSnapshot, replacing id: String? = nil) throws -> Self {
        var value = self
        value.ip = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        value.mac = try RouterAddress.mac(mac)
        value.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ip = RouterAddress.ipv4(value.ip), RouterAddress.isPrivate(ip),
              ip & snapshot.mask == snapshot.lanIP & snapshot.mask,
              ip != snapshot.lanIP, ip & ~snapshot.mask != 0, ip & ~snapshot.mask != ~snapshot.mask else {
            throw RouterFailure(message: "IP 必须位于路由器 LAN 网段内，且不能是网关、网络地址或广播地址。")
        }
        guard value.name.utf8.count <= 32, !value.name.contains(where: { $0.isNewline }) else {
            throw RouterFailure(message: "设备名称最多 32 个 UTF-8 字节，且不能包含换行。")
        }
        guard !snapshot.bindings.contains(where: { $0.id != id && ($0.ip == value.ip || $0.mac == value.mac) }) else {
            throw RouterFailure(message: "该 IP 或 MAC 已有绑定，请编辑现有记录。")
        }
        guard !snapshot.devices.contains(where: { $0.online && $0.ip == value.ip && $0.mac != value.mac }) else {
            throw RouterFailure(message: "该 IP 正由另一台在线设备使用，请选择其他地址。")
        }
        return value
    }
}

struct RouterSnapshot: Equatable, Sendable {
    let devices: [RouterDevice]
    let bindings: [RouterBinding]
    let lanIP: UInt32
    let mask: UInt32
    let mode: Int
    var routerMode: Bool { mode == 0 }
    var onlineDevices: [RouterDevice] { devices.filter { $0.online && !$0.blocked } }
    var offlineDevices: [RouterDevice] { devices.filter { !$0.online && !$0.blocked } }
    var blockedDevices: [RouterDevice] { devices.filter(\.blocked) }
    var nextBindingName: String {
        var index = 1
        let names = Set(bindings.map(\.id))
        while names.contains("user_bind_\(index)") { index += 1 }
        return "user_bind_\(index)"
    }

    init(_ object: [String: Any]) throws {
        guard let network = object["network"] as? [String: Any], let lan = network["lan"] as? [String: Any],
              let ip = RouterAddress.ipv4(Self.text(lan["ipaddr"])),
              let mask = RouterAddress.ipv4(Self.text(lan["netmask"])),
              mask != 0, ~mask >= 3, (~mask & (~mask &+ 1)) == 0 else { throw RouterFailure(message: "路由器未返回有效的 LAN 地址与子网掩码。") }
        self.lanIP = ip; self.mask = mask
        guard let system = object["system"] as? [String: Any], let state = system["sys_mode"] as? [String: Any],
              let mode = Int(Self.text(state["mode"])), (0...2).contains(mode) else { throw RouterFailure(message: "路由器未返回可识别的工作模式。") }
        self.mode = mode
        var merged: [String: RouterDevice] = [:]
        for table in ["offline_host", "online_host", "blocked_host"] {
          for (_, row) in try Self.rows(object, module: "hosts_info", table: table) {
            let mac = try RouterAddress.mac(Self.text(row["mac"]))
            let type = Self.text(row["type"]), band = Self.text(row["wifi_mode"])
            let link = type == "0" ? "有线" : type == "2" ? "访客 Wi-Fi" : band == "0" ? "2.4 GHz" : band == "1" ? "5 GHz" : "Wi-Fi"
            var device = RouterDevice(id: mac, name: Self.name(row["hostname"], fallback: mac), ip: Self.text(row["ip"]), mac: mac,
                                connection: link, upload: Double(Self.text(row["up_speed"])) ?? 0,
                                download: Double(Self.text(row["down_speed"])) ?? 0)
            device.online = table == "online_host" || merged[mac]?.online == true
            device.blocked = table == "blocked_host" || ["1", "true"].contains(Self.text(row["blocked"]))
            device.isCurrent = ["1", "true"].contains(Self.text(row["is_cur_host"]))
            device.ipv6 = Self.text(row["ipv6"]); device.ssid = Self.name(row["ssid"], fallback: "")
            device.rssi = Self.text(row["rssi"]); device.connectedSeconds = Self.text(row["connect_time"])
            device.uploadLimit = Self.text(row["up_limit"]); device.downloadLimit = Self.text(row["down_limit"])
            merged[mac] = device
          }
        }
        devices = merged.values.sorted {
            if $0.isCurrent != $1.isCurrent { return $0.isCurrent }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        bindings = try Self.rows(object, module: "ip_mac_bind", table: "user_bind").map { id, row in
            guard Self.validSection(id), RouterAddress.ipv4(Self.text(row["ip"])) != nil else { throw RouterFailure(message: "路由器绑定表包含无效条目。") }
            return RouterBinding(id: id, ip: Self.text(row["ip"]), mac: try RouterAddress.mac(Self.text(row["mac"])),
                                 name: Self.name(row["hostname"], fallback: ""))
        }.sorted { $0.ip.localizedStandardCompare($1.ip) == .orderedAscending }
        guard Set(devices.map(\.id)).count == devices.count, Set(bindings.map(\.id)).count == bindings.count else {
            throw RouterFailure(message: "路由器返回的设备或绑定条目有重复编号。")
        }
    }

    static func validSection(_ id: String) -> Bool {
        id.hasPrefix("user_bind_") && !id.dropFirst(10).isEmpty && id.dropFirst(10).utf8.allSatisfy({ (48...57).contains($0) })
    }
    private static func text(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return ""
    }
    private static func name(_ value: Any?, fallback: String) -> String {
        let raw = text(value), decoded = raw.removingPercentEncoding ?? raw
        return decoded.isEmpty ? fallback : decoded
    }
    private static func rows(_ object: [String: Any], module: String, table: String) throws -> [(String, [String: Any])] {
        guard let module = object[module] as? [String: Any], let rows = module[table] as? [[String: Any]] else {
            throw RouterFailure(message: "路由器未返回 \(module)/\(table) 列表。")
        }
        return try rows.map { row in
            guard row.count == 1, let entry = row.first, let fields = entry.value as? [String: Any] else { throw RouterFailure.incompatible }
            return (entry.key, fields)
        }
    }
}

enum RouterPassword {
    // TL-XDR5480 web UI's orgAuthPwd/securityEncode protocol, using JavaScript UTF-16 units.
    static func encode(_ password: String) -> String {
        let key = Array("RDpbLfCPsJZ7fiv".utf16), input = Array(password.utf16)
        let alphabet = Array("yLwVl0zKqws7LgKPRQ84Mdt708T1qQ3Ha7xv3H7NyU84p21BriUWBU43odz3iP4rBL3cD02KZciXTysVXiV8ngg6vL48rPJyAUw0HurW20xqxv9aYb4M9wK1Ae0wlro510qXeU07kV57fQMc8L6aLgMLwygtc0F10a0Dg70TOoouyFhdysuRMO51yY5ZlOZZLEal1h0t9YQW0Ko7oBwmCAHoic4HYbUyVeU3sfQ1xtXcPcf1aT303wAQhv66qzW")
        return String((0..<max(key.count, input.count)).map { index in
            alphabet[Int((index < key.count ? key[index] : 187) ^ (index < input.count ? input[index] : 187)) % alphabet.count]
        })
    }
}
