import Foundation
import Security

private final class FakeKeychain: KeychainOperations {
    struct Item {
        var service: String; var account: String; var cloud: Bool; var data: Data; var protection: String
    }
    var items: [Item] = []
    var failCloudWrites = false
    var events: [String] = []
    private func matches(_ item: Item, _ query: [String: Any]) -> Bool {
        guard item.service == query[kSecAttrService as String] as? String else { return false }
        if let account = query[kSecAttrAccount as String] as? String, account != item.account { return false }
        if query[kSecAttrSynchronizable as String] as? String == kSecAttrSynchronizableAny as String { return true }
        return item.cloud == (query[kSecAttrSynchronizable as String] as? Bool ?? false)
    }
    func read(_ query: [String: Any]) -> (OSStatus, Any?) {
        let found = items.filter { matches($0, query) }
        guard !found.isEmpty else { return (errSecItemNotFound, nil) }
        if query[kSecReturnAttributes as String] as? Bool == true {
            let values: [[String: Any]] = found.map { [kSecAttrAccount as String: $0.account,
                kSecValueData as String: $0.data, kSecAttrAccessible as String: $0.protection] }
            return (errSecSuccess, values)
        }
        return (errSecSuccess, found[0].data)
    }
    func add(_ attributes: [String: Any]) -> OSStatus {
        if failCloudWrites, attributes[kSecAttrSynchronizable as String] as? Bool == true { return errSecInteractionNotAllowed }
        if items.contains(where: { matches($0, attributes) }) { return errSecDuplicateItem }
        items.append(Item(service: attributes[kSecAttrService as String] as! String,
                          account: attributes[kSecAttrAccount as String] as! String,
                          cloud: attributes[kSecAttrSynchronizable as String] as? Bool ?? false,
                          data: attributes[kSecValueData as String] as! Data,
                          protection: attributes[kSecAttrAccessible as String] as! String))
        events.append("add")
        return errSecSuccess
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        if failCloudWrites, query[kSecAttrSynchronizable as String] as? Bool == true { return errSecInteractionNotAllowed }
        guard let index = items.firstIndex(where: { matches($0, query) }) else { return errSecItemNotFound }
        items[index].data = attributes[kSecValueData as String] as! Data
        items[index].protection = attributes[kSecAttrAccessible as String] as! String
        events.append("update")
        return errSecSuccess
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        items.removeAll { matches($0, query) }; events.append("delete"); return errSecSuccess
    }
}

@main struct CloudKeychainTests {
    static func main() throws {
        let fake = FakeKeychain(), bytes = Data("original-secret".utf8)
        let github = "me.stackli.hako.github", console = "me.stackli.hako.console"
        fake.items = [.init(service: github, account: "token", cloud: false, data: bytes,
                            protection: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)]
        let storage = SecureStorage.namespace(github, operations: fake)
        let original = try storage.read(account: "token")
        precondition(original == bytes)
        fake.failCloudWrites = true
        let failed = SecureStorage.prepareCloudCredentials(operations: fake)
        precondition(failed.failures == [errSecInteractionNotAllowed] && fake.items.count == 1 && !fake.items[0].cloud)
        fake.failCloudWrites = false
        let prepared = SecureStorage.prepareCloudCredentials(operations: fake)
        precondition(prepared.prepared == 1 && prepared.failures.isEmpty)
        precondition(fake.events == ["add", "delete"], "Legacy secret removed before cloud save succeeded")
        precondition(fake.items.count == 1 && fake.items[0].cloud && fake.items[0].data == bytes)
        precondition(fake.items[0].protection == kSecAttrAccessibleAfterFirstUnlock as String)
        let local = SecureStorage.namespace(console, operations: fake)
        try local.save(bytes, account: "identity.device.v1", accessibility: .whenUnlocked)
        let identity = fake.items.first { $0.service == console }!
        precondition(!identity.cloud && identity.protection == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        let newer = Data("remote-value".utf8)
        fake.items.append(.init(service: github, account: "token", cloud: false, data: Data("old".utf8), protection: kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String))
        try storage.save(newer, account: "token", accessibility: .afterFirstUnlock)
        let read = try storage.read(account: "token")
        precondition(read == newer && fake.items.filter { $0.service == github }.count == 1)
        fake.items.append(.init(service: github, account: "token", cloud: false, data: bytes, protection: kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String))
        _ = SecureStorage.prepareCloudCredentials(operations: fake)
        let preferred = try storage.read(account: "token")
        precondition(preferred == newer, "Migration overwrote an existing cloud credential")
        try storage.delete(account: "token")
        let deleted = try storage.read(account: "token")
        precondition(deleted == nil && fake.items.allSatisfy { $0.service == console }, "Deletion resurrected a legacy value")
        print("PASS: cloud keychain policy, safe migration, failure preservation, device identity isolation and synchronized deletion")
    }
}
