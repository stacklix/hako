import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum HakoServerCompatibility {
    private static let minimumServerVersion = "0.3.1"
    private static let invalidMetadata = "服务端返回的版本信息无效，请检查 Hako 服务端版本。"

    private struct Versions: Decodable {
        let serverVersion: String
        let minimumIosVersion: String?
    }

    struct Result: Sendable {
        let serverVersion: String?
        let warning: String?
    }

    static func check(origin: String) async throws -> Result {
        guard var components = URLComponents(string: origin),
              components.scheme == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else { throw URLError(.badURL) }
        components.path = "/api/v1/version"
        guard let url = components.url else { throw URLError(.badURL) }
        let request = URLRequest(url: url, timeoutInterval: 5)
        let (data, response) = try await HTTPTransport.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode
        if status == 404 || status == 405 {
            return Result(serverVersion: nil, warning: "服务端未提供版本信息，请确认服务器地址并检查是否已升级到 Hako 服务端 \(minimumServerVersion) 或更高版本。")
        }
        guard status == 200 else { throw URLError(.badServerResponse) }
        let iosVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return evaluate(data, iosVersion: iosVersion)
    }

    static func evaluate(_ data: Data, iosVersion: String) -> Result {
        guard let versions = try? JSONDecoder().decode(Versions.self, from: data),
              let server = parse(versions.serverVersion) else {
            return Result(serverVersion: nil, warning: invalidMetadata)
        }
        guard let minimumIOS = versions.minimumIosVersion.flatMap(parse) else {
            return Result(serverVersion: versions.serverVersion, warning: invalidMetadata)
        }
        guard let client = parse(iosVersion), let minimumServer = parse(minimumServerVersion) else {
            return Result(serverVersion: versions.serverVersion, warning: "无法读取 Hako iOS 版本，请重新安装 Hako。")
        }
        let warnings = [
            mismatch(client, minimum: minimumIOS, component: "Hako iOS", requiredBy: "服务端"),
            mismatch(server, minimum: minimumServer, component: "服务端", requiredBy: "Hako iOS"),
        ].compactMap { $0 }
        return Result(serverVersion: versions.serverVersion, warning: warnings.isEmpty ? nil : warnings.joined(separator: "\n\n"))
    }

    private static func mismatch(_ current: [Int32], minimum: [Int32], component: String, requiredBy: String) -> String? {
        let version = current.map(String.init).joined(separator: ".")
        let floor = minimum.map(String.init).joined(separator: ".")
        let line = "\(minimum[0]).\(minimum[1]).x"
        if current.lexicographicallyPrecedes(minimum) {
            return "\(component) 当前为 \(version)，\(requiredBy) 要求 \(line) 版本且至少为 \(floor)。请升级 \(component)。"
        }
        if current.prefix(2) != minimum.prefix(2) {
            return "\(component) 当前为 \(version)，超出了 \(requiredBy) 支持的 \(line) 版本。请升级 \(requiredBy)。"
        }
        return nil
    }

    private static func parse(_ version: String) -> [Int32]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else {
            return nil
        }
        let numbers = parts.compactMap { Int32($0) }
        return numbers.count == 3 ? numbers : nil
    }
}
