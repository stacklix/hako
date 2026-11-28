import Foundation

enum HakoTokens {
    static let service = "me.stackli.hako.financial-tokens"
    private static let metadataLock = NSLock()
    private static var metadata: Result<[HakoTokenDefinition], Error>?

    // Installed synchronously by the app before any child page is created.
    static func configure(declarations: [HakoCredentialDeclaration]) {
        let result = Result { try HakoTokenMetadata.load(declarations: declarations) }
        metadataLock.lock()
        defer { metadataLock.unlock() }
        metadata = result
    }

    private static func definitions() throws -> [HakoTokenDefinition] {
        metadataLock.lock()
        defer { metadataLock.unlock() }
        guard let metadata else { throw HakoTokenError.invalidDeclaration }
        return try metadata.get()
    }
    static let shared = HakoTokenVault(storage: SecureStorage.namespace(service), definitions: { try definitions() })

    static func read(_ key: String) throws -> String { try shared.readKey(key) }

    static func readGroup(containing key: String) throws -> [String: String] {
        try shared.read(shared.definition(containing: key).id).values
    }

    static func saveGroup(_ values: [String: String]) throws {
        guard let key = values.keys.first else { throw HakoTokenError.invalidDeclaration }
        try shared.save(values, for: shared.definition(containing: key).id)
    }

}
