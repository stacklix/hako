import Foundation

private final class MemorySecrets: SecretStorage {
    var values: [String: Data] = [:]
    var writes = 0
    var accessibility: SecretAccessibility?
    var failWrites = false
    func read(account: String) throws -> Data? { values[account] }
    func save(_ data: Data, account: String, accessibility: SecretAccessibility) throws {
        if failWrites { throw SecretStorageError(status: -1) }
        writes += 1; values[account] = data; self.accessibility = accessibility
    }
    func delete(account: String) throws { values.removeValue(forKey: account) }
    func accounts() throws -> [String] { Array(values.keys) }
}

@main struct CredentialStorageTests {
    static func main() throws {
        let arcane = MemorySecrets(), ecs = MemorySecrets()
        let empty = try ArcaneKeychain.load(storage: arcane)
        precondition(empty == nil)
        let connection = ArcaneConnection(name: " Example ", address: "https://example.com/api/", apiKey: " test-key ")
        try ArcaneKeychain.save(connection, storage: arcane)
        let restored = try ArcaneKeychain.load(storage: arcane)!
        precondition(restored.name == "Example" && restored.address == "https://example.com" && restored.apiKey == "test-key")
        precondition(arcane.accessibility == .whenUnlocked)
        var invalid = connection; invalid.apiKey = ""
        do { try ArcaneKeychain.save(invalid, storage: arcane); fatalError("Invalid configuration saved") }
        catch is ArcaneFailure { }
        precondition(arcane.writes == 1)
        arcane.failWrites = true
        do { try ArcaneKeychain.save(connection, storage: arcane); fatalError("Storage failure ignored") }
        catch is ArcaneFailure { }
        let preserved = try ArcaneKeychain.load(storage: arcane)
        precondition(preserved == restored)

        var server = ECSConnection()
        server.instanceID = " i-example "; server.accessKeyID = " key "; server.accessKeySecret = " secret "
        try ECSKeychain.save(server, storage: ecs)
        let savedServer = try ECSKeychain.load(storage: ecs)!
        precondition(savedServer.instanceID == "i-example" && savedServer.accessKeyID == "key")
        precondition(ecs.accessibility == .whenUnlocked && arcane.values != ecs.values)
        server.instanceID = "invalid"
        do { try ECSKeychain.save(server, storage: ecs); fatalError("Invalid ECS configuration saved") }
        catch is ECSFailure { }
        precondition(ecs.writes == 1)
        ecs.values["connection"] = Data("broken".utf8)
        do { _ = try ECSKeychain.load(storage: ecs); fatalError("Corrupt data accepted") }
        catch is DecodingError { }
        print("Credential contract tests passed: validation, normalization, schema isolation, accessibility and failure preservation")
    }
}
