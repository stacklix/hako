import Foundation

@main @MainActor struct ArcaneCommandDataTests {
    static func main() async throws {
        let suite = "hako-command-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let connection = ArcaneConnection(name: "Test", address: "https://example.invalid", apiKey: "key")
        let store = ArcaneStore(connection: connection, defaults: defaults, clientFactory: { _ in fatalError("No network request is expected in lock tests") })
        let bytes = Data(#"{"id":"container","name":"/app","state":{"status":"running","running":true},"labels":{"com.docker.compose.project":"demo","com.docker.compose.service":"web"}}"#.utf8)
        let details = try JSONDecoder().decode(ArcaneContainerDetails.self, from: bytes)
        let context = ArcaneCommandContext(connection: connection.id, environment: "0", details: details)
        let library = ArcaneCommandLibrary(defaults: defaults)
        var definition = ArcaneCommandDefinition(name: "Test", template: "command {{password}}", parameters: [ArcaneCommandParameter(key: "password", name: "Password", kind: .password, defaultValue: "never-store")])
        try library.save(definition, context: context)
        let saved = library.definitions(context)
        precondition(saved.count == 1 && saved[0].parameters[0].defaultValue.isEmpty)
        precondition(!String(decoding: defaults.data(forKey: context.stableKey)!, as: UTF8.self).contains("never-store"))
        definition.name = "Updated"; try library.save(definition, context: context)
        precondition(library.definitions(context).count == 1 && library.definitions(context)[0].name == "Updated")
        let other = ArcaneCommandContext(connection: "other", environment: "0", details: details)
        precondition(library.definitions(other).isEmpty)
        try library.remove(definition, context: context); precondition(library.definitions(context).isEmpty)

        let token = try store.beginTerminalSession()
        do { _ = try store.beginTerminalSession(); fatalError("Concurrent session accepted") } catch is ArcaneFailure { }
        do { try await store.withFileSave { fatalError("File mutation ran during terminal session") }; fatalError("Concurrent save accepted") } catch is ArcaneFailure { }
        let environment = try JSONDecoder().decode(ArcaneEnvironment.self, from: Data(#"{"id":"0","name":"Local"}"#.utf8))
        store.start(.restart, container: details, environment: environment)
        precondition(store.pending == nil && !store.operationRunning)
        store.endTerminalSession(UUID()); precondition(store.terminalSessionID == token, "An old session cannot release another session's lease")
        store.endTerminalSession(token); precondition(store.terminalSessionID == nil)
        try await store.withFileSave {
            do { _ = try store.beginTerminalSession(); fatalError("Terminal acquired during save") } catch is ArcaneFailure { }
        }
        print("PASS: template persistence/secret defaults/scope isolation, terminal/command/save/lifecycle exclusion and lease ownership")
    }
}
