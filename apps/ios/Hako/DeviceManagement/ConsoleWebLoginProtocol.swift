import Foundation

enum ConsoleWebLoginError: LocalizedError {
    case invalidRequest, serverMismatch, expired
    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "这不是有效的 Hako 网页登录二维码。"
        case .serverMismatch: return "二维码的服务器与当前配置不一致，已停止处理。"
        case .expired: return "二维码已过期，请在网页刷新后重新扫码。"
        }
    }
}

struct ConsoleWebLoginPayload {
    let requestId: String
    init(_ payload: String, origin: String) throws {
        guard payload.utf8.count <= 2048,
              let url = URLComponents(string: payload), url.scheme == "hako", url.host == "admin-login",
              url.user == nil, url.password == nil, url.port == nil, url.path.isEmpty, url.fragment == nil,
              let items = url.queryItems, items.count == 3 else { throw ConsoleWebLoginError.invalidRequest }
        var values: [String: String] = [:]
        for item in items {
            guard ["v", "server", "request"].contains(item.name), values[item.name] == nil, let value = item.value else {
                throw ConsoleWebLoginError.invalidRequest
            }
            values[item.name] = value
        }
        guard values["v"] == "1", let id = values["request"], Self.validID(id) else { throw ConsoleWebLoginError.invalidRequest }
        guard values["server"] == origin,
              let server = URLComponents(string: origin), server.scheme == "https", server.host?.isEmpty == false,
              server.user == nil, server.password == nil, server.path.isEmpty, server.query == nil, server.fragment == nil else {
            throw ConsoleWebLoginError.serverMismatch
        }
        requestId = id
    }
    static func validID(_ text: String) -> Bool {
        text.range(of: "\\A[A-Za-z0-9_-]{43}\\z", options: .regularExpression) != nil
    }
}

struct ConsoleWebLoginRequest: Decodable, Identifiable {
    let id: String
    let origin: String
    let confirmationCode: String
    let browser: String
    var clientIP: String? = nil
    let requestedAt: String
    let expiresAt: String
    let nonce: String
    var expiry: Date? { ISO8601DateFormatter().date(from: expiresAt) }

    func validate(origin expected: String, requestId: String) throws {
        guard origin == expected else { throw ConsoleWebLoginError.serverMismatch }
        guard id == requestId, ConsoleWebLoginPayload.validID(id), ConsoleWebLoginPayload.validID(nonce),
              confirmationCode.range(of: "\\A[0-9]{6}\\z", options: .regularExpression) != nil else { throw ConsoleWebLoginError.invalidRequest }
        guard let expiry, expiry > Date.now else { throw ConsoleWebLoginError.expired }
    }
}
