import Foundation

/// Child-owned declarations contain metadata only; values stay in the host Keychain.
struct HakoCredentialDefinition {
    let title: String
    let fields: [HakoTokenField]
    let validatorID: String
}

struct HakoCredentialDeclaration {
    let application: String
    let applicationName: String
    let credentials: [HakoCredentialDefinition]
}

enum HakoTokenMetadata {
    static func load(declarations: [HakoCredentialDeclaration]) throws -> [HakoTokenDefinition] {
        var definitions: [String: HakoTokenDefinition] = [:]
        var applications = Set<String>()
        var keyOwners: [String: String] = [:]
        for declaration in declarations.sorted(by: { $0.application < $1.application }) {
            guard validKey(declaration.application), applications.insert(declaration.application).inserted,
                  !declaration.applicationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw HakoTokenError.invalidDeclaration
            }
            var groups = Set<String>()
            for credential in declaration.credentials {
                guard !credential.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !credential.fields.isEmpty,
                      validKey(credential.validatorID) else {
                    throw HakoTokenError.invalidDeclaration
                }
                let fields = credential.fields.sorted { $0.key < $1.key }
                guard fields.allSatisfy({ validKey($0.key) && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                      Set(fields.map(\.key)).count == fields.count else { throw HakoTokenError.invalidDeclaration }
                let id = fields.map(\.key).joined(separator: "|")
                guard groups.insert(id).inserted else { throw HakoTokenError.invalidDeclaration }
                for field in fields {
                    if let owner = keyOwners[field.key], owner != id { throw HakoTokenError.invalidDeclaration }
                    keyOwners[field.key] = id
                }
                let name = declaration.applicationName
                if let existing = definitions[id] {
                    guard existing.validatorID == credential.validatorID else { throw HakoTokenError.invalidDeclaration }
                    definitions[id] = HakoTokenDefinition(id: id, title: existing.title, applications: existing.applications + [name],
                        applicationIDs: existing.applicationIDs + [declaration.application], fields: existing.fields, validatorID: credential.validatorID)
                } else {
                    definitions[id] = HakoTokenDefinition(id: id, title: credential.title, applications: [name],
                        applicationIDs: [declaration.application], fields: fields, validatorID: credential.validatorID)
                }
            }
        }
        guard !applications.isEmpty else { throw HakoTokenError.invalidDeclaration }
        return definitions.values.sorted { $0.id < $1.id }
    }

    private static func validKey(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z][A-Za-z0-9_.-]*$", options: .regularExpression) != nil
    }
}
