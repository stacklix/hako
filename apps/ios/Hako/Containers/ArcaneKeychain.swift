import Foundation
import Security

enum ArcaneKeychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "me.stackli.hako.arcane",
        kSecAttrAccount as String: "connection"
    ]

    static func load() throws -> ArcaneConnection? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ArcaneFailure(message: "无法读取 Arcane 凭据（\(status)），请解锁手机后重试。")
        }
        return try JSONDecoder().decode(ArcaneConnection.self, from: data)
    }

    static func save(_ connection: ArcaneConnection) throws {
        let normalized = try connection.normalized()
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(normalized),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ArcaneFailure(message: "无法保存 Arcane 连接（\(status)），原配置已保留。") }
    }
}
