import Foundation
import Security

enum SecretAccessibility { case whenUnlocked, afterFirstUnlock }

protocol SecretStorage {
    func read(account: String) throws -> Data?
    func save(_ data: Data, account: String, accessibility: SecretAccessibility) throws
    func delete(account: String) throws
    func accounts() throws -> [String]
}

struct SecretStorageError: Error, LocalizedError, CustomNSError {
    let status: OSStatus
    var context: String? = nil
    var errorDescription: String? { (context.map { $0 + "失败：" } ?? "") + "安全存储操作失败（\(status)），请解锁设备后重试。" }
    static var errorDomain: String { NSOSStatusErrorDomain }
    var errorCode: Int { Int(status) }
    var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: errorDescription ?? "安全存储操作失败。"] }
}

// A service namespace scopes every operation, including enumeration and deletion.
enum SecureStorage {
    fileprivate static let operationLock = NSRecursiveLock()
    static func namespace(_ service: String) -> any SecretStorage { KeychainStorage(service: service) }
    static func namespace(_ service: String, operations: any KeychainOperations) -> any SecretStorage {
        KeychainStorage(service: service, operations: operations)
    }

    // Device identities and server sessions deliberately remain device-bound.
    static let synchronizedServices: Set<String> = [
        "me.stackli.hako.github", "me.stackli.hako.language-model", "me.stackli.hako.headplane",
        "me.stackli.hako.qinglong", "me.stackli.hako.arcane", "me.stackli.hako.ecs",
        "me.stackli.hako.devices.ssh", "me.stackli.hako.investment", "me.stackli.hako.commands", "me.stackli.hako.crypto"
    ]

    struct CloudPreparation: Sendable {
        var prepared = 0
        var failures: [OSStatus] = []
    }

    static func prepareCloudCredentials() -> CloudPreparation {
        prepareCloudCredentials(operations: SystemKeychainOperations())
    }

    static func prepareCloudCredentials(operations: any KeychainOperations) -> CloudPreparation {
        var result = CloudPreparation()
        for service in synchronizedServices.sorted() {
            let storage = KeychainStorage(service: service, operations: operations)
            do { result.prepared += try storage.migrateLocalItems() }
            catch let error as SecretStorageError { result.failures.append(error.status) }
            catch { result.failures.append(errSecInternalError) }
        }
        return result
    }
}

protocol KeychainOperations {
    func read(_ query: [String: Any]) -> (OSStatus, Any?)
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

private struct SystemKeychainOperations: KeychainOperations {
    func read(_ query: [String: Any]) -> (OSStatus, Any?) {
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        return (status, value)
    }
    func add(_ attributes: [String: Any]) -> OSStatus { SecItemAdd(attributes as CFDictionary, nil) }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }
    func delete(_ query: [String: Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }
}

private struct KeychainStorage: SecretStorage {
    let service: String
    var operations: any KeychainOperations = SystemKeychainOperations()
    private var synchronized: Bool { SecureStorage.synchronizedServices.contains(service) }

    private func query(_ account: String? = nil, cloud: Bool = false, any: Bool = false) -> [String: Any] {
        var value: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let account { value[kSecAttrAccount as String] = account }
        value[kSecAttrSynchronizable as String] = any ? kSecAttrSynchronizableAny as Any : cloud
        #if os(macOS)
        value[kSecUseDataProtectionKeychain as String] = true
        #endif
        return value
    }
    func read(account: String) throws -> Data? {
        SecureStorage.operationLock.lock()
        defer { SecureStorage.operationLock.unlock() }
        if synchronized, let data = try readData(query(account, cloud: true)) { return data }
        return try readData(query(account))
    }
    private func readData(_ query: [String: Any]) throws -> Data? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        let (status, result) = operations.read(lookup)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw SecretStorageError(status: status) }
        return data
    }
    func save(_ data: Data, account: String, accessibility: SecretAccessibility) throws {
        SecureStorage.operationLock.lock()
        defer { SecureStorage.operationLock.unlock() }
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: protection(accessibility)]
        let lookup = query(account, cloud: synchronized)
        var status = operations.update(lookup, attributes: attributes)
        if status == errSecItemNotFound { status = operations.add(lookup.merging(attributes) { _, new in new }) }
        guard status == errSecSuccess else { throw SecretStorageError(status: status) }
        // Retire a legacy local item only after the new value is durably in Keychain.
        if synchronized { _ = operations.delete(query(account)) }
    }
    func delete(account: String) throws {
        SecureStorage.operationLock.lock()
        defer { SecureStorage.operationLock.unlock() }
        // Delete both generations so a removed cloud item cannot resurrect from an old local copy.
        let status = operations.delete(query(account, any: synchronized))
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStorageError(status: status) }
    }
    func accounts() throws -> [String] {
        SecureStorage.operationLock.lock()
        defer { SecureStorage.operationLock.unlock() }
        var lookup = query(any: synchronized)
        lookup[kSecReturnAttributes as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitAll
        let (status, result) = operations.read(lookup)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { throw SecretStorageError(status: status) }
        return Array(Set(items.compactMap { $0[kSecAttrAccount as String] as? String })).sorted()
    }

    private func protection(_ accessibility: SecretAccessibility) -> CFString {
        if synchronized { return accessibility == .whenUnlocked ? kSecAttrAccessibleWhenUnlocked : kSecAttrAccessibleAfterFirstUnlock }
        return accessibility == .whenUnlocked ? kSecAttrAccessibleWhenUnlockedThisDeviceOnly : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    }

    func migrateLocalItems() throws -> Int {
        SecureStorage.operationLock.lock()
        defer { SecureStorage.operationLock.unlock() }
        guard synchronized else { return 0 }
        var lookup = query()
        lookup[kSecReturnAttributes as String] = true
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitAll
        let (status, result) = operations.read(lookup)
        if status == errSecItemNotFound { return 0 }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { throw SecretStorageError(status: status) }
        var prepared = 0
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String, let data = item[kSecValueData as String] as? Data else {
                throw SecretStorageError(status: errSecDecode)
            }
            // A cloud copy from another device takes precedence. Keep a differing
            // local copy intact instead of overwriting a newer remote credential.
            if try readData(query(account, cloud: true)) != nil { continue }
            let original = item[kSecAttrAccessible as String] as? String
            let accessibility: SecretAccessibility = original == (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
                || original == (kSecAttrAccessibleAfterFirstUnlock as String) ? .afterFirstUnlock : .whenUnlocked
            let attributes = query(account, cloud: true).merging([
                kSecValueData as String: data, kSecAttrAccessible as String: protection(accessibility)
            ]) { _, new in new }
            let added = operations.add(attributes)
            if added == errSecDuplicateItem { continue }
            guard added == errSecSuccess else { throw SecretStorageError(status: added) }
            _ = operations.delete(query(account))
            prepared += 1
        }
        return prepared
    }
}
