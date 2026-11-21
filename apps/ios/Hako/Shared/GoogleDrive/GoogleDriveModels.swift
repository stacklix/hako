import Foundation

struct GoogleDriveError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct GoogleDriveSettings: Codable, Equatable {
    var clientID = ""
    var parentDirectory = "Hako"
    func validate() throws {
        _ = try GoogleDriveOAuth.redirectURI(clientID: clientID)
        guard !(try HakoBackupPath.components(parentDirectory)).isEmpty else {
            throw GoogleDriveError(message: "请填写主应用的备份父目录。")
        }
    }
}

enum GoogleDrivePath {
    static func queryLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    }
}

struct GoogleDriveConnectionSettings: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = ""
    var clientID = ""
    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GoogleDriveError(message: "请填写连接名称，例如个人账号。")
        }
        _ = try GoogleDriveOAuth.redirectURI(clientID: clientID)
    }
}

enum GoogleDriveOAuth {
    static let scope = "https://www.googleapis.com/auth/drive.file"

    static func redirectURI(clientID: String) throws -> String {
        let suffix = ".apps.googleusercontent.com"
        let prefix = clientID.hasSuffix(suffix) ? String(clientID.dropLast(suffix.count)) : ""
        guard !prefix.isEmpty, prefix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
            throw GoogleDriveError(message: "请输入 Google Cloud 创建的 iOS OAuth Client ID，以 .apps.googleusercontent.com 结尾。")
        }
        return "com.googleusercontent.apps.\(prefix):/oauthredirect"
    }

    static func authorizationURL(clientID: String, state: String, challenge: String) throws -> URL {
        var url = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        url.queryItems = ["client_id": clientID, "redirect_uri": try redirectURI(clientID: clientID),
            "response_type": "code", "scope": scope, "state": state, "code_challenge": challenge,
            "code_challenge_method": "S256", "access_type": "offline", "prompt": "consent select_account"].map(URLQueryItem.init)
        return url.url!
    }

    static func authorizationCode(_ callback: URL, clientID: String, state: String) throws -> String {
        let expected = URL(string: try redirectURI(clientID: clientID))!
        guard let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              parts.scheme == expected.scheme, parts.host == nil, parts.path == expected.path,
              parts.fragment == nil, parts.user == nil, parts.password == nil else {
            throw GoogleDriveError(message: "Google 授权回调地址无效。")
        }
        let items = parts.queryItems ?? []
        guard items.filter({ $0.name == "state" }).count == 1,
              items.first(where: { $0.name == "state" })?.value == state else {
            throw GoogleDriveError(message: "Google 授权状态不匹配，请重新连接。")
        }
        if items.contains(where: { $0.name == "error" }) { throw GoogleDriveError(message: "Google 授权未完成，请重新连接并允许备份权限。") }
        guard items.filter({ $0.name == "code" }).count == 1,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw GoogleDriveError(message: "Google 未返回授权码。")
        }
        return code
    }

    static func form(_ fields: [String: String]) -> Data {
        var parts = URLComponents()
        parts.queryItems = fields.sorted(by: { $0.key < $1.key }).map(URLQueryItem.init)
        return Data(parts.percentEncodedQuery!.replacingOccurrences(of: "+", with: "%2B").utf8)
    }
}

struct GoogleDriveCredential: Codable {
    var clientID: String
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
}

struct GoogleDriveBackupReceipt: Codable {
    let fileID: String
    let path: String
    let byteCount: Int
    let completedAt: Date
}
