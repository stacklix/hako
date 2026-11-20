import Foundation

enum WorkshopNetworkConfiguration {
    static func connectionFailureMessage(_ error: Error) -> String {
        let failure = error as NSError
        guard failure.domain == NSURLErrorDomain else { return error.localizedDescription }
        let message: String
        switch URLError.Code(rawValue: failure.code) {
        case .timedOut:
            message = "连接超时，未收到电脑的代码工坊握手响应。请检查手机与电脑是否互通，以及防火墙是否允许该端口。"
        case .cannotConnectToHost:
            message = "无法连接此端口，请确认电脑上的 Agent 已开启局域网服务。"
        case .notConnectedToInternet, .dataNotAllowed:
            message = "当前网络不可用，请检查 Wi-Fi 及系统设置中 Hako 的局域网权限。"
        case .networkConnectionLost:
            message = "与电脑的连接中断，请重试测试连接。"
        case .appTransportSecurityRequiresSecureConnection:
            message = "系统阻止了局域网明文连接，请检查应用的网络安全配置。"
        default:
            message = error.localizedDescription
        }
        return message + "（\(failure.domain) \(failure.code)）"
    }
    enum ConnectionError: LocalizedError {
        case wrongComputer
        var errorDescription: String? { "局域网地址对应的电脑与所选执行电脑不一致，请检查该电脑的地址配置。" }
    }
    static func requireComputer(_ hello: Data, agentID: String) throws {
        struct Welcome: Decodable { let computerId: String }
        guard try JSONDecoder().decode(Welcome.self, from: hello).computerId == agentID else {
            throw ConnectionError.wrongComputer
        }
    }
    private static let key = "hako.workshop.network.endpoints"

    static func endpoints(namespace: String, defaults: UserDefaults = .standard) -> [String: LocalNetworkEndpoint] {
        read(defaults)[namespace, default: [:]].filter { !$0.key.isEmpty && $0.value.isValid }
    }

    static func load(agentID: String, namespace: String, defaults: UserDefaults = .standard) -> LocalNetworkEndpoint? {
        endpoints(namespace: namespace, defaults: defaults)[agentID]
    }

    static func save(_ endpoint: LocalNetworkEndpoint?, agentID: String, namespace: String, defaults: UserDefaults = .standard) throws {
        guard !agentID.isEmpty, endpoint?.isValid != false else { throw CocoaError(.coderInvalidValue) }
        var configuration = read(defaults)
        configuration[namespace, default: [:]][agentID] = endpoint
        defaults.set(try JSONEncoder().encode(configuration), forKey: key)
    }

    private static func read(_ defaults: UserDefaults) -> [String: [String: LocalNetworkEndpoint]] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: [String: LocalNetworkEndpoint]].self, from: data)) ?? [:]
    }
}
