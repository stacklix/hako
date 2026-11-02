import Foundation
import Security

enum SecretAccessibility { case whenUnlocked, afterFirstUnlock }

protocol SecretStorage {
    func read(account: String) throws -> Data?
    func save(_ data: Data, account: String, accessibility: SecretAccessibility) throws
    func delete(account: String) throws
    func accounts() throws -> [String]
}

struct SecretStorageError: Error, LocalizedError {
    let status: OSStatus
    var errorDescription: String? { "安全存储操作失败（\(status)），请解锁设备后重试。" }
}

// A service namespace scopes every operation, including enumeration and deletion.
enum SecureStorage {
    static func namespace(_ service: String) -> any SecretStorage { KeychainStorage(service: service) }
}

private struct KeychainStorage: SecretStorage {
    let service: String
    private func query(_ account: String? = nil) -> [String: Any] {
        var value: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let account { value[kSecAttrAccount as String] = account }
        return value
    }
    func read(account: String) throws -> Data? {
        var lookup = query(account)
        lookup[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw SecretStorageError(status: status) }
        return data
    }
    func save(_ data: Data, account: String, accessibility: SecretAccessibility) throws {
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility == .whenUnlocked
                ? kSecAttrAccessibleWhenUnlockedThisDeviceOnly : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let lookup = query(account)
        var status = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(lookup.merging(attributes) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw SecretStorageError(status: status) }
    }
    func delete(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStorageError(status: status) }
    }
    func accounts() throws -> [String] {
        var lookup = query()
        lookup[kSecReturnAttributes as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { throw SecretStorageError(status: status) }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}
