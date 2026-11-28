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

@main struct HakoTokenMetadataTests {
    static func main() throws {
        let shared = credential("Shared", ["shared.api-key"])
        let first = try document("investment", [shared, credential("Exchange", ["exchange.api-key", "exchange.secret-key"])])
        let second = try document("crypto", [shared])
        let definitions = try HakoTokenMetadata.load(declarations: [first, second])
        var conflicting = shared
        conflicting = .init(title: shared.title, fields: shared.fields, validatorID: "different.validator")
        let conflictingDocument = try document("crypto", [conflicting])
        expectFailure { _ = try HakoTokenMetadata.load(declarations: [first, conflictingDocument]) }
        precondition(definitions.count == 2)
        let group = definitions.first { $0.id == "shared.api-key" }!
        precondition(group.applicationIDs == ["crypto", "investment"] && group.fields.map(\.key) == ["shared.api-key"])
        precondition(definitions.first { $0.title == "Exchange" }?.fields.count == 2)
        try verifyUnifiedPersistence(definitions)

        // Adding a registered child declaration requires no service-specific host dispatch.
        let third = try document("newFinanceChild", [credential("New service", ["new-service.token"])])
        precondition(tryLoad([first, second, third]).contains { $0.id == "new-service.token" })
        expectFailure { _ = try HakoTokenMetadata.load(declarations: [first, first]) }
        let partialPair = try document("other", [credential("Exchange", ["exchange.api-key"])])
        expectFailure { _ = try HakoTokenMetadata.load(declarations: [first, partialPair]) }
        let duplicateKey = try document("other", [credential("Duplicate", ["same", "same"])])
        expectFailure { _ = try HakoTokenMetadata.load(declarations: [duplicateKey]) }
        let badKey = try document("other", [credential("Bad", ["key with whitespace"])])
        expectFailure { _ = try HakoTokenMetadata.load(declarations: [badKey]) }
        expectFailure { _ = try HakoTokenMetadata.load(declarations: []) }
        let stock = try document("stockTrade", [])
        precondition(tryLoad([stock]).isEmpty)
        print("Token declarations: shared keys, atomic groups, new child registration and invalid declarations passed")
    }

    private static func verifyUnifiedPersistence(_ definitions: [HakoTokenDefinition]) throws {
        let host = MetadataMemorySecrets()
        let vault = HakoTokenVault(storage: host, definitions: { definitions })
        let values = ["shared.api-key": "fixture-shared", "exchange.api-key": "fixture-key", "exchange.secret-key": "fixture-secret"]
        for definition in definitions {
            let group = Dictionary(uniqueKeysWithValues: definition.fields.map { ($0.key, values[$0.key]!) })
            try vault.save(group, for: definition.id)
        }
        precondition(host.items.count == 2)
        let reopened = HakoTokenVault(storage: host, definitions: { definitions })
        for (key, value) in values { precondition(try! reopened.readKey(key) == value) }
        let shared = try reopened.read("shared.api-key")
        precondition(Set(shared.applicationIDs) == Set(["investment", "crypto"]))
        try reopened.saveKey("shared.api-key", value: "")
        precondition(try! vault.readKey("shared.api-key") == "")
    }

    private static func credential(_ name: String, _ keys: [String]) -> HakoCredentialDefinition {
        .init(title: name, fields: keys.map { .init(key: $0, title: "API Key") },
              validatorID: "fixture." + keys.sorted().joined(separator: "."))
    }
    private static func document(_ application: String, _ credentials: [HakoCredentialDefinition]) throws -> HakoCredentialDeclaration {
        .init(application: application, applicationName: application, credentials: credentials)
    }
    private static func tryLoad(_ declarations: [HakoCredentialDeclaration]) -> [HakoTokenDefinition] {
        try! HakoTokenMetadata.load(declarations: declarations)
    }
    private static func expectFailure(_ action: () throws -> Void) {
        do { try action(); preconditionFailure("Expected failure") } catch { }
    }
}

private final class MetadataMemorySecrets: SecretStorage {
    var items: [String: Data] = [:]
    func read(account: String) throws -> Data? { items[account] }
    func save(_ data: Data, account: String, accessibility: SecretAccessibility) throws { items[account] = data }
    func delete(account: String) throws { items[account] = nil }
    func accounts() throws -> [String] { Array(items.keys) }
}
