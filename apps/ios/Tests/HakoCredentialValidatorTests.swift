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

private enum FixtureValidator: HakoCredentialValidator {
    static let identifier = "fixture.validator"
    static let keys: Set<String> = ["fixture.key", "fixture.secret"]
    static var calls = 0
    static func validate(_ credentials: [String: String]) async throws -> HakoCredentialValidationResult {
        calls += 1
        precondition(Set(credentials.keys) == keys)
        return .init(status: .passed, message: "Accepted " + credentials["fixture.key"]! + " / " + credentials["fixture.secret"]!
            + " / " + Data(credentials["fixture.secret"]!.utf8).base64EncodedString())
    }
}
private enum FailingValidator: HakoCredentialValidator {
    static let identifier = "fixture.fail"
    static let keys: Set<String> = ["fixture.key"]
    static func validate(_ credentials: [String: String]) async throws -> HakoCredentialValidationResult {
        throw URLError(.timedOut)
    }
}
private enum CancelledValidator: HakoCredentialValidator {
    static let identifier = "fixture.cancel"
    static let keys: Set<String> = ["fixture.key"]
    static func validate(_ credentials: [String: String]) async throws -> HakoCredentialValidationResult {
        throw CancellationError()
    }
}

@main struct HakoCredentialValidatorTests {
    @MainActor static func main() async throws {
        let registry = HakoCredentialValidatorRegistry()
        registry.register(FixtureValidator.self)
        let definition = HakoTokenDefinition(id: "pair", title: "Pair", applications: ["Fixture"],
            fields: [.init(key: "fixture.key", title: "Key"), .init(key: "fixture.secret", title: "Secret")], validatorID: FixtureValidator.identifier)
        precondition(registry.supports(definition))
        let values = ["fixture.key": "fixture-private-key", "fixture.secret": "fixture-private-secret"]
        let result = try await registry.validate(definition, credentials: values)
        precondition(result.status == .passed && !result.message.contains("fixture-private"))
        precondition(!result.message.contains(Data(values["fixture.secret"]!.utf8).base64EncodedString()))
        let incomplete = try await registry.validate(definition, credentials: ["fixture.key": "key"])
        precondition(incomplete.status == .invalidCredentials && FixtureValidator.calls == 1)
        let unrelated = try await registry.validate(definition, credentials: values.merging(["unrelated.key": "do-not-pass"]) { a, _ in a })
        precondition(unrelated.status == .invalidCredentials && FixtureValidator.calls == 1)
        var wrong = definition; wrong.validatorID = "missing"
        precondition(!registry.supports(wrong))
        let unsupported = try await registry.validate(wrong, credentials: values)
        precondition(unsupported.status == .unavailable)
        registry.register(FailingValidator.self)
        let scalar = HakoTokenDefinition(id: "scalar", title: "Scalar", applications: ["Fixture"],
            fields: [.init(key: "fixture.key", title: "Key")], validatorID: FailingValidator.identifier)
        let timeout = try await registry.validate(scalar, credentials: ["fixture.key": "fixture-value"])
        precondition(timeout.status == .unavailable, "A network timeout must not mark a key invalid")
        registry.register(CancelledValidator.self)
        var cancelled = scalar; cancelled.validatorID = CancelledValidator.identifier
        do { _ = try await registry.validate(cancelled, credentials: ["fixture.key": "fixture-value"]); preconditionFailure("Cancellation swallowed") }
        catch is CancellationError { }
        let duplicate = HakoCredentialValidatorRegistry()
        duplicate.register(FixtureValidator.self); duplicate.register(FixtureValidator.self)
        precondition(!duplicate.registrationErrors.isEmpty && !duplicate.supports(definition))
        print("Credential registry: dispatch, exact key isolation, redaction, duplicate rejection, timeout and cancellation passed")
    }
}
