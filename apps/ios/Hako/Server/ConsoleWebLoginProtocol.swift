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
    let isApplication: Bool
    init(_ payload: String, origin: String) throws {
        guard payload.utf8.count <= 2048,
              let url = URLComponents(string: payload), url.scheme == "hako", url.host == "web-login",
              url.user == nil, url.password == nil, url.port == nil, url.path.isEmpty, url.fragment == nil,
              let items = url.queryItems, items.count == 3 else { throw ConsoleWebLoginError.invalidRequest }
        var values: [String: String] = [:]
        for item in items {
            guard ["v", "server", "request"].contains(item.name), values[item.name] == nil, let value = item.value else {
                throw ConsoleWebLoginError.invalidRequest
            }
            values[item.name] = value
        }
        guard ["1", "2"].contains(values["v"] ?? ""), let id = values["request"], Self.validID(id) else { throw ConsoleWebLoginError.invalidRequest }
        guard values["server"] == origin,
              let server = URLComponents(string: origin), server.scheme == "https", server.host?.isEmpty == false,
              server.user == nil, server.password == nil, server.path.isEmpty, server.query == nil, server.fragment == nil else {
            throw ConsoleWebLoginError.serverMismatch
        }
        requestId = id
        isApplication = values["v"] == "2"
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
    var application: String? = nil
    var applicationOrigin: String? = nil
    var purpose: String? = nil
    var isApplication: Bool { !(application ?? "").isEmpty }
    var expiry: Date? { ISO8601DateFormatter().date(from: expiresAt) }

    func validate(origin expected: String, requestId: String, applicationRequest: Bool? = nil) throws {
        guard origin == expected else { throw ConsoleWebLoginError.serverMismatch }
        guard id == requestId, ConsoleWebLoginPayload.validID(id), ConsoleWebLoginPayload.validID(nonce),
              confirmationCode.range(of: "\\A[0-9]{6}\\z", options: .regularExpression) != nil else { throw ConsoleWebLoginError.invalidRequest }
        guard let expiry, expiry > Date.now else { throw ConsoleWebLoginError.expired }
        if let applicationRequest, applicationRequest != isApplication { throw ConsoleWebLoginError.invalidRequest }
        if isApplication {
            guard let application, !application.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  ["bind", "login"].contains(purpose ?? ""), let target = applicationOrigin,
                  let url = URLComponents(string: target), url.scheme == "https", url.host?.isEmpty == false,
                  url.user == nil, url.password == nil, url.path.isEmpty, url.query == nil, url.fragment == nil else { throw ConsoleWebLoginError.invalidRequest }
        } else if !(applicationOrigin ?? "").isEmpty || !(purpose ?? "").isEmpty { throw ConsoleWebLoginError.invalidRequest }
    }
}
