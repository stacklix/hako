import Foundation

struct ECSSocketEndpoint: Equatable {
    let address: String
    let port: Int
    var family: String { address == "*" ? "通配地址" : address.contains(":") ? "IPv6" : "IPv4" }

    init?(_ value: String) {
        guard let separator = value.lastIndex(of: ":"),
              let port = Int(value[value.index(after: separator)...]), (1...65535).contains(port) else { return nil }
        let address = String(value[..<separator]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !address.isEmpty else { return nil }
        self.address = address; self.port = port
    }
}

struct ECSListeningPort: Identifiable {
    let protocolName: String
    let port: Int?
    let sockets: [ECSSocket]
    var id: String { protocolName + "|" + (port.map(String.init) ?? sockets.first?.local ?? "") }
    var name: String { port.map(String.init) ?? "未知端口" }
    var processes: String {
        let names = Set(sockets.compactMap(\.process)).sorted()
        return names.isEmpty ? "进程信息不可用" : names.joined(separator: "、")
    }
    static func grouped(_ sockets: [ECSSocket]) -> [Self] {
        let groups = Dictionary(grouping: sockets.filter { $0.listening && ($0.namespace == nil || $0.namespace == "host") }) {
            $0.protocolName + "|" + (ECSSocketEndpoint($0.local).map { String($0.port) } ?? $0.local)
        }
        return groups.values.map { values in
            Self(protocolName: values[0].protocolName, port: ECSSocketEndpoint(values[0].local)?.port,
                 sockets: values.sorted { $0.id < $1.id })
        }.sorted {
            if $0.port != $1.port { return ($0.port ?? Int.max) < ($1.port ?? Int.max) }
            return $0.id < $1.id
        }
    }
}

enum ECSConnectionDirection: String, Identifiable {
    case outgoing, incoming
    var id: String { rawValue }
    var title: String { self == .outgoing ? "主动连接" : "被动连接" }
    func count(_ summary: ECSConnectionCounts?) -> Int? { self == .outgoing ? summary?.outgoing : summary?.incoming }
    func sockets(_ values: [ECSSocket]) -> [ECSSocket] {
        values.filter { $0.established && $0.direction == rawValue }.sorted { $0.id < $1.id }
    }
}

struct ECSNetworkRate {
    let value: String
    let unit: String
    init(_ bytes: Double?) {
        guard let bytes, bytes.isFinite, bytes >= 0 else { value = "—"; unit = ""; return }
        let units = ["B/s", "KiB/s", "MiB/s", "GiB/s", "TiB/s"]
        var amount = bytes, index = 0
        while amount >= 1024 && index < units.count - 1 { amount /= 1024; index += 1 }
        value = amount.formatted(.number.precision(.fractionLength(0...1)))
        unit = units[index]
    }
}
