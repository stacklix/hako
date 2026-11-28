import Foundation

#if !canImport(Security)
enum SecretAccessibility { case whenUnlocked, afterFirstUnlock }
protocol SecretStorage {
    func read(account: String) throws -> Data?
    func save(_ data: Data, account: String, accessibility: SecretAccessibility) throws
    func delete(account: String) throws
    func accounts() throws -> [String]
}
#endif

private enum TestFailure: Error { case denied }
private final class MemorySecrets: SecretStorage {
    var items: [String: Data] = [:]
    var deniedRead = false
    var deniedWrite = false
    func read(account: String) throws -> Data? {
        if deniedRead { throw TestFailure.denied }
        return items[account]
    }
    func save(_ data: Data, account: String, accessibility: SecretAccessibility) throws {
        if deniedWrite { throw TestFailure.denied }
        items[account] = data
    }
    func delete(account: String) throws { items[account] = nil }
    func accounts() throws -> [String] { Array(items.keys) }
}

@main struct HakoTokenVaultTests {
    static func main() throws {
        try persistedV1RecordsRemainReadable()
        try atomicPairsAndFailureRecovery()
        try invalidDataIsPreserved()
        try declarationsAndMissingRecords()
        print("Token vault: persisted v1 values/associations, clear/reload, atomic pairs and failure recovery passed")
    }

    private static func persistedV1RecordsRemainReadable() throws {
        let host = MemorySecrets()
        // Exact persisted shape from the previous release, without using Record's encoder.
        let fixture = Data(#"""
        {"version":1,"id":"twelve-data.api-key","title":"Twelve Data",
         "applications":["投资记账","加密资产"],"applicationIDs":["investment","crypto"],
         "fields":[{"key":"twelve-data.api-key","title":"API Key"}],
         "values":{"twelve-data.api-key":"fixture-saved-key"},"migrated":true}
        """#.utf8)
        host.items["twelve-data.api-key"] = fixture
        let definition = HakoTokenDefinition(id: "twelve-data.api-key", title: "Twelve Data",
            applications: ["投资记账", "加密资产"], applicationIDs: ["investment", "crypto"],
            fields: [.init(key: "twelve-data.api-key", title: "API Key")])
        let vault = HakoTokenVault(storage: host, definitions: { [definition] })
        let record = try vault.read(definition.id)
        precondition(record.values[definition.id] == "fixture-saved-key")
        precondition(record.applicationIDs == ["investment", "crypto"] && record.migrated)
        precondition(host.items[definition.id] == fixture, "Reading must not rewrite an existing matching record")
        try vault.saveKey(definition.id, value: " fixture-updated ")
        let reopened = HakoTokenVault(storage: host, definitions: { [definition] })
        precondition(try! reopened.readKey(definition.id) == "fixture-updated")
        let saved = try reopened.read(definition.id)
        precondition(saved.applicationIDs == record.applicationIDs && saved.fields == record.fields && saved.migrated)
        try reopened.saveKey(definition.id, value: "")
        let cleared = try vault.read(definition.id)
        precondition(cleared.values[definition.id] == "" && cleared.applicationIDs == record.applicationIDs)
        precondition(host.items[definition.id] != nil)
    }

    private static func atomicPairsAndFailureRecovery() throws {
        let host = MemorySecrets()
        let definition = HakoTokenDefinition(id: "pair", title: "Pair", applications: ["Crypto"],
            fields: [.init(key: "pair.key", title: "Key"), .init(key: "pair.secret", title: "Secret")])
        let vault = HakoTokenVault(storage: host, definitions: { [definition] })
        try vault.save(["pair.key": "fixture-key", "pair.secret": "fixture-secret"], for: "pair")
        let original = host.items
        expectFailure { try vault.saveKey("pair.key", value: "partial") }
        expectFailure { try vault.save(["pair.key": "changed", "pair.secret": ""], for: "pair") }
        expectFailure { try vault.save(["pair.key": "bad\nvalue", "pair.secret": "value"], for: "pair") }
        precondition(host.items == original)
        host.deniedWrite = true
        expectFailure { try vault.save(["pair.key": "changed", "pair.secret": "changed-secret"], for: "pair") }
        precondition(host.items == original)
        host.deniedWrite = false
        try vault.save(["pair.key": "changed", "pair.secret": "changed-secret"], for: "pair")
        let reopened = HakoTokenVault(storage: host, definitions: { [definition] })
        precondition(try! reopened.read("pair").values == ["pair.key": "changed", "pair.secret": "changed-secret"])
    }

    private static func invalidDataIsPreserved() throws {
        let host = MemorySecrets()
        let definition = HakoTokenDefinition(id: "source", title: "Source", applications: ["A"],
            fields: [.init(key: "token", title: "Token")])
        let vault = HakoTokenVault(storage: host, definitions: { [definition] })
        host.deniedRead = true
        expectFailure { _ = try vault.read("source") }
        expectFailure { try vault.saveKey("token", value: "replacement") }
        precondition(host.items.isEmpty)
        host.deniedRead = false
        host.items["source"] = Data("corrupt".utf8)
        expectFailure { _ = try vault.read("source") }
        expectFailure { try vault.saveKey("token", value: "replacement") }
        precondition(host.items["source"] == Data("corrupt".utf8))
    }

    private static func declarationsAndMissingRecords() throws {
        let host = MemorySecrets()
        let definition = HakoTokenDefinition(id: "one", title: "One", applications: ["A"], fields: [.init(key: "key", title: "Key")])
        let duplicate = HakoTokenVault(storage: host, definitions: { [definition, definition] })
        expectFailure { _ = try duplicate.definitions() }
        let other = HakoTokenDefinition(id: "two", title: "Two", applications: ["B"], fields: definition.fields)
        let duplicateKey = HakoTokenVault(storage: host, definitions: { [definition, other] })
        expectFailure { _ = try duplicateKey.definitions() }
        let vault = HakoTokenVault(storage: host, definitions: { [definition] })
        expectFailure { _ = try vault.read("unknown") }
        let empty = try vault.read("one")
        precondition(!empty.migrated && empty.values == ["key": ""] && host.items.isEmpty)
        try vault.saveKey("key", value: "fixture-new")
        precondition(try! vault.readKey("key") == "fixture-new")
    }

    private static func expectFailure(_ action: () throws -> Void) {
        do { try action(); preconditionFailure("Expected a failure") } catch { }
    }
}
