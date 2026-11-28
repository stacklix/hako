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

// Stall a real migration call at the Security boundary without stalling the
// fake's storage lock. Unrelated services must remain usable during the stall.
private final class BlockingKeychain: KeychainOperations, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let storage = FakeKeychain()
    private var shouldBlock = true
    private let service = "me.stackli.hako.arcane"

    init() {
        storage.items = [.init(service: service, account: "token", cloud: false,
                               data: Data("legacy".utf8), protection: kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)]
    }
    func read(_ query: [String: Any]) -> (OSStatus, Any?) {
        lock.lock()
        let block = shouldBlock && query[kSecAttrService as String] as? String == service
            && query[kSecReturnAttributes as String] as? Bool == true
        if block { shouldBlock = false }
        lock.unlock()
        if block {
            entered.signal()
            precondition(release.wait(timeout: .now() + 5) == .success)
        }
        lock.lock(); defer { lock.unlock() }
        return storage.read(query)
    }
    func add(_ attributes: [String: Any]) -> OSStatus {
        lock.lock(); defer { lock.unlock() }; return storage.add(attributes)
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        lock.lock(); defer { lock.unlock() }; return storage.update(query, attributes: attributes)
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        lock.lock(); defer { lock.unlock() }; return storage.delete(query)
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
        try stalledMigrationDoesNotBlockConsole()
        print("PASS: cloud keychain policy, safe migration, failure preservation, device identity isolation and synchronized deletion")
    }

    private static func stalledMigrationDoesNotBlockConsole() throws {
        let fake = BlockingKeychain()
        let migrated = DispatchSemaphore(value: 0), consoleRead = DispatchSemaphore(value: 0)
        let writeAttempted = DispatchSemaphore(value: 0), written = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let result = SecureStorage.prepareCloudCredentials(operations: fake)
            precondition(result.prepared == 1 && result.failures.isEmpty)
            migrated.signal()
        }
        precondition(fake.entered.wait(timeout: .now() + 2) == .success)
        DispatchQueue.global().async {
            let console = SecureStorage.namespace("me.stackli.hako.console", operations: fake)
            precondition((try! console.read(account: "identity.device.v1")) == nil)
            consoleRead.signal()
        }
        precondition(consoleRead.wait(timeout: .now() + 1) == .success,
                     "Slow cloud migration blocked the device identity used at startup")
        DispatchQueue.global().async {
            let sameService = SecureStorage.namespace("me.stackli.hako.arcane", operations: fake)
            writeAttempted.signal()
            try! sameService.save(Data("new".utf8), account: "token", accessibility: .whenUnlocked)
            written.signal()
        }
        precondition(writeAttempted.wait(timeout: .now() + 1) == .success)
        precondition(written.wait(timeout: .now() + 0.1) == .timedOut,
                     "Same-service save raced credential migration")
        fake.release.signal()
        precondition(migrated.wait(timeout: .now() + 2) == .success)
        precondition(written.wait(timeout: .now() + 2) == .success)
        let value = try SecureStorage.namespace("me.stackli.hako.arcane", operations: fake).read(account: "token")
        precondition(value == Data("new".utf8), "Migration replaced a concurrent credential update")
    }
}
