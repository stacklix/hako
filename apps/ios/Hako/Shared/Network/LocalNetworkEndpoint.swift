import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum LocalNetworkApplication: String, Codable, CaseIterable, Identifiable {
    case codeWorkshop
    var id: String { rawValue }
    var title: String { "代码工坊" }
}

struct LocalNetworkEndpoint: Codable, Equatable, Sendable {
    let ip: String
    let port: Int

    init?(ip: String, port: Int) {
        let ip = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...65535).contains(port), Self.isLocalIP(ip) else { return nil }
        self.ip = ip; self.port = port
    }

    var address: String { "\(ip.contains(":") ? "[\(ip)]" : ip):\(port)" }

    func url(scheme: String = "ws", path: String = "/") -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = ip.contains(":") ? "[\(ip)]" : ip
        components.port = port; components.path = path
        return components.url
    }

    var isValid: Bool { (1...65535).contains(port) && Self.isLocalIP(ip) }

    private static func isLocalIP(_ value: String) -> Bool {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, value, &ipv4) == 1 {
            let bytes = value.split(separator: ".").compactMap { Int($0) }
            return bytes.count == 4 && (bytes[0] == 10 || bytes[0] == 192 && bytes[1] == 168 ||
                bytes[0] == 172 && (16...31).contains(bytes[1]) || bytes[0] == 169 && bytes[1] == 254)
        }
        var ipv6 = in6_addr()
        guard inet_pton(AF_INET6, value, &ipv6) == 1 else { return false }
        return withUnsafeBytes(of: &ipv6) { bytes in
            bytes[0] & 0xfe == 0xfc || bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80
        }
    }
}

struct LocalNetworkConfiguration: Codable, Equatable {
    var ssids: [String] = []
    var endpoints: [String: LocalNetworkEndpoint] = [:]

    func isLocal(ssid: String?, usesWiFi: Bool) -> Bool {
        guard usesWiFi, let ssid, !ssid.isEmpty else { return false }
        return ssids.contains { $0.utf8.elementsEqual(ssid.utf8) }
    }

    func endpoint(for application: LocalNetworkApplication, ssid: String?, usesWiFi: Bool) -> LocalNetworkEndpoint? {
        guard isLocal(ssid: ssid, usesWiFi: usesWiFi), let value = endpoints[application.rawValue], value.isValid else { return nil }
        return value
    }
}
