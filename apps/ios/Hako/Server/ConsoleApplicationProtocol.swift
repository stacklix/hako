import Foundation

struct ConsoleApplicationOIDC: Codable, Equatable {
    var enabled: Bool
    var redirectURIs: [String]
    var scopes: [String]
    var requirePKCE: Bool
    var authMethod: String
}

struct ConsoleApplication: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let origin: String
    var enabled: Bool
    let createdAt: String
    var oidc: ConsoleApplicationOIDC?
    var usesOIDC: Bool { oidc?.enabled == true }
    var loginMethods: String { usesOIDC ? "OIDC · 扫码登录" : "扫码登录" }

    func configuration(issuer: String, secret: String? = nil) -> String {
        var lines = ["HAKO_URL=\(issuer)", "HAKO_CLIENT_ID=\(id)"]
        if let secret { lines.append("HAKO_CLIENT_SECRET=\(secret)") }
        if let oidc {
            lines += ["OIDC_ISSUER=\(issuer)", "OIDC_ENABLED=\(oidc.enabled)",
                      "OIDC_REDIRECT_URIS=\(oidc.redirectURIs.joined(separator: ","))",
                      "OIDC_SCOPES=\(oidc.scopes.joined(separator: " "))",
                      "OIDC_AUTH_METHOD=\(oidc.authMethod)", "OIDC_REQUIRE_PKCE=\(oidc.requirePKCE)"]
        }
        return lines.joined(separator: "\n")
    }
}

struct ConsoleApplicationDraft: Equatable {
    var name = ""
    var origin = ""
    var oidcEnabled = false
    var redirects = ""
    var profile = true
    var requirePKCE = true
    var authMethod = "client_secret_basic"
    private var originalOIDC: ConsoleApplicationOIDC?

    init(application: ConsoleApplication? = nil) {
        guard let application else { return }
        name = application.name; origin = application.origin
        originalOIDC = application.oidc
        if let oidc = application.oidc {
            oidcEnabled = oidc.enabled; redirects = oidc.redirectURIs.joined(separator: "\n")
            profile = oidc.scopes.contains("profile"); requirePKCE = oidc.requirePKCE; authMethod = oidc.authMethod
        }
    }
    var hasRequiredInput: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !origin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && (!oidcEnabled || !redirects.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    func validatedOIDC() throws -> ConsoleApplicationOIDC? {
        guard oidcEnabled || originalOIDC != nil else { return nil }
        let values = redirects.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !values.isEmpty, values.count <= 16, Set(values).count == values.count,
              ["client_secret_basic", "client_secret_post"].contains(authMethod) else {
            throw ConsoleApplicationError.invalidOIDC
        }
        for value in values {
            guard value.utf8.count <= 2048, let url = URLComponents(string: value), url.scheme == "https",
                  let host = url.host, !host.isEmpty, url.user == nil, url.password == nil, url.fragment == nil,
                  !value.contains(where: { $0.isWhitespace || $0.isNewline }),
                  !value.contains("*"), !value.contains("\\"), !value.contains("#"),
                  !host.contains(where: { "'\";<>".contains($0) }), !url.authorityHasEmptyPort,
                  url.port == nil || (1...65535).contains(url.port!),
                  !(url.queryItems ?? []).contains(where: { ["code", "state", "error", "error_description", "iss"].contains($0.name) }) else {
                throw ConsoleApplicationError.invalidOIDC
            }
        }
        return ConsoleApplicationOIDC(enabled: oidcEnabled, redirectURIs: values, scopes: profile ? ["openid", "profile"] : ["openid"], requirePKCE: requirePKCE, authMethod: authMethod)
    }
    func creationBody() throws -> [String: Any] {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var origin = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        if origin.hasSuffix("/") { origin.removeLast() }
        guard !name.isEmpty, name.utf8.count <= 80, !name.contains(where: { $0.isNewline }),
              ConsoleWebLoginRequest.validApplicationOrigin(origin) else { throw ConsoleApplicationError.invalidDetails }
        var body: [String: Any] = ["name": name, "origin": origin]
        if let oidc = try validatedOIDC() { body["oidc"] = try oidc.body() }
        return body
    }
    func updateBody() throws -> [String: Any] {
        guard let oidc = try validatedOIDC() else { throw ConsoleApplicationError.unchanged }
        return ["oidc": try oidc.body()]
    }
}
private extension URLComponents {
    var authorityHasEmptyPort: Bool { (url?.absoluteString.components(separatedBy: "/").dropFirst(2).first ?? "").hasSuffix(":") }
}
private extension ConsoleApplicationOIDC {
    func body() throws -> [String: Any] {
        guard let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as? [String: Any] else { throw ConsoleApplicationError.invalidOIDC }
        return body
    }
}

struct ConsoleApplicationList: Decodable { let applications: [ConsoleApplication]; let issuer: String }
struct ConsoleApplicationResult: Decodable { let application: ConsoleApplication }
struct ConsoleApplicationSecretResponse: Decodable { let application: ConsoleApplication; let clientSecret: String }
struct ConsoleApplicationCredential: Identifiable {
    let id = UUID()
    let application: ConsoleApplication
    let secret: String
    let issuer: String
    let context: String
}
enum ConsoleApplicationError: LocalizedError {
    case invalidDetails, invalidOIDC, unchanged, invalidResponse, loginRequired, busy
    var errorDescription: String? {
        switch self {
        case .invalidDetails: return "请填写应用名称（最多 80 个 UTF-8 字节）与有效的根地址，支持 HTTPS 或局域网 HTTP。"
        case .invalidOIDC: return "请登记 1–16 个不重复的精确 HTTPS 回调地址，不包含通配符、用户凭据、片段或 code/state 等保留参数。"
        case .unchanged: return "尚未修改 OIDC 配置。"
        case .invalidResponse: return "服务器返回的应用配置无效，请确认服务端已更新。"
        case .loginRequired: return "请先使用已登记的本机设备身份登录 Hako 服务器。"
        case .busy: return "正在处理应用请求，请稍后重试。"
        }
    }
}
