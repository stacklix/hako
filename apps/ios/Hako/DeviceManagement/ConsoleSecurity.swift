import Foundation
import CryptoKit
import Security

enum ConsoleKeychain {
    static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "me.stackli.hako.console",
         kSecAttrAccount as String: account]
    }
    static func read(_ account: String) throws -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw HakoError(message: "无法读取设备凭据（\(status)），请解锁手机后重试。")
        }
        return data
    }
    static func save(_ account: String, data: Data) throws {
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query(account).merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw HakoError(message: "无法保存设备凭据（\(status)）。") }
    }
    static func delete(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw HakoError(message: "无法清除设备凭据（\(status)）。") }
    }
}

struct ConsoleIdentity: Codable {
    let deviceId: String
    let keyRepresentation: Data

    static func load(origin: String) throws -> Self {
        let account = "identity." + origin.consoleDigest
        if let data = try ConsoleKeychain.read(account) { return try JSONDecoder().decode(Self.self, from: data) }
        guard SecureEnclave.isAvailable else { throw HakoError(message: "设备绑定需要支持 Secure Enclave 的 iPhone。") }
        var error: Unmanaged<CFError>?
        guard let control = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .privateKeyUsage, &error) else {
            throw HakoError(message: "无法创建设备密钥访问控制。")
        }
        let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: control)
        let bytes = key.publicKey.x963Representation
        let jwk = ["kty": "EC", "crv": "P-256", "x": Data(bytes[1..<33]).consoleBase64URL, "y": Data(bytes[33..<65]).consoleBase64URL]
        let canonical = try JSONSerialization.data(withJSONObject: jwk, options: [.sortedKeys])
        let identity = Self(deviceId: Data(SHA256.hash(data: canonical)).consoleBase64URL, keyRepresentation: key.dataRepresentation)
        try ConsoleKeychain.save(account, data: JSONEncoder().encode(identity))
        return identity
    }

    func publicKeyPEM() throws -> String {
        try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: keyRepresentation).publicKey.pemRepresentation
    }

    func proof(method: String, url: URL, accessToken: String?, nonce: String? = nil) throws -> String {
        let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: keyRepresentation)
        let bytes = key.publicKey.x963Representation
        let jwk = ["kty": "EC", "crv": "P-256", "x": Data(bytes[1..<33]).consoleBase64URL, "y": Data(bytes[33..<65]).consoleBase64URL]
        let header: [String: Any] = ["typ": "dpop+jwt", "alg": "ES256", "jwk": jwk]
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.query = nil; components.fragment = nil
        var claims: [String: Any] = ["htm": method, "htu": components.url!.absoluteString,
            "iat": Int(Date.now.timeIntervalSince1970), "jti": UUID().uuidString.lowercased()]
        if let nonce { claims["nonce"] = nonce }
        if let accessToken { claims["ath"] = accessToken.consoleDigest }
        let encoded = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]).consoleBase64URL + "." + JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys]).consoleBase64URL
        let signature = try key.signature(for: Data(encoded.utf8)).rawRepresentation.consoleBase64URL
        return encoded + "." + signature
    }
}

extension Data {
    var consoleBase64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}
extension String {
    var consoleDigest: String { Data(SHA256.hash(data: Data(utf8))).consoleBase64URL }
}
