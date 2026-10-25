import Foundation

// Exercise persistence and migration without requiring Secure Enclave on a CI host.
@main struct ConsoleIdentityTests {
    enum StorageError: Error { case unavailable }

    static func main() throws {
        var stored: [String: Data] = [:]
        var generated = 0
        func load(_ origin: String? = nil) throws -> ConsoleIdentity {
            try ConsoleIdentity.load(origin: origin, read: { stored[$0] }, save: { stored[$0] = $1 }, generate: {
                generated += 1
                return ConsoleIdentity(deviceId: "test-device-\(generated)", keyRepresentation: Data("test-wrapped-key-\(generated)".utf8))
            })
        }
        let first = try load()
        precondition(generated == 1 && stored[ConsoleIdentity.deviceAccount] != nil)
        let repeated = try load()
        precondition(repeated.deviceId == first.deviceId && repeated.keyRepresentation == first.keyRepresentation && generated == 1)

        let origin = "https://monitor.example.com"
        let bound = try load(origin)
        precondition(bound.deviceId == first.deviceId && bound.keyRepresentation == first.keyRepresentation && generated == 1)
        precondition(stored["identity." + origin.consoleDigest] == stored[ConsoleIdentity.deviceAccount])

        stored = [:]; generated = 0
        let legacy = ConsoleIdentity(deviceId: "legacy-device", keyRepresentation: Data("legacy-wrapped-key".utf8))
        let legacyData = try JSONEncoder().encode(legacy)
        stored["identity." + origin.consoleDigest] = legacyData
        let migrated = try load(origin)
        precondition(migrated.deviceId == legacy.deviceId && migrated.keyRepresentation == legacy.keyRepresentation && generated == 0)
        let unconfigured = try load()
        let newServer = try load("https://new.example.com")
        precondition(unconfigured.keyRepresentation == legacy.keyRepresentation && newServer.keyRepresentation == legacy.keyRepresentation && generated == 0)

        let otherOrigin = "https://other.example.com"
        let other = ConsoleIdentity(deviceId: "other-legacy-device", keyRepresentation: Data("other-legacy-wrapped-key".utf8))
        stored["identity." + otherOrigin.consoleDigest] = try JSONEncoder().encode(other)
        let otherLoaded = try load(otherOrigin)
        let defaultLoaded = try load()
        precondition(otherLoaded.keyRepresentation == other.keyRepresentation && defaultLoaded.keyRepresentation == legacy.keyRepresentation)

        let corruptAccount = "identity." + "https://corrupt.example.com".consoleDigest
        stored[corruptAccount] = Data("invalid identity".utf8)
        let before = stored
        do { _ = try load("https://corrupt.example.com"); fatalError("Corrupt identity was silently replaced") }
        catch is DecodingError { }
        precondition(stored == before && generated == 0)

        do {
            _ = try ConsoleIdentity.load(read: { _ in throw StorageError.unavailable }, save: { _, _ in fatalError("Saved after failed read") },
                                         generate: { fatalError("Generated after failed read") })
            fatalError("Keychain read error was ignored")
        } catch StorageError.unavailable { }
        do {
            _ = try ConsoleIdentity.load(read: { _ in nil }, save: { _, _ in throw StorageError.unavailable }, generate: { legacy })
            fatalError("Unsaved identity was returned for export")
        } catch StorageError.unavailable { }

        // A reset must commit a usable replacement before retiring the old key.
        stored = [ConsoleIdentity.deviceAccount: legacyData, "identity." + origin.consoleDigest: legacyData]
        let original = stored
        let replacement = ConsoleIdentity(deviceId: "replacement-device", keyRepresentation: Data("replacement-wrapped-key".utf8))
        do {
            _ = try ConsoleIdentity.reset(save: { stored[$0] = $1 }, generate: { throw StorageError.unavailable }, prepare: { _ in })
            fatalError("Failed generation reset the identity")
        } catch StorageError.unavailable { }
        precondition(stored == original)
        do {
            _ = try ConsoleIdentity.reset(save: { stored[$0] = $1 }, generate: { replacement }, prepare: { _ in throw StorageError.unavailable })
            fatalError("Unusable replacement was committed")
        } catch StorageError.unavailable { }
        precondition(stored == original)
        do {
            _ = try ConsoleIdentity.reset(save: { _, _ in throw StorageError.unavailable }, generate: { replacement }, prepare: { _ in })
            fatalError("Reset ignored persistence failure")
        } catch StorageError.unavailable { }
        precondition(stored == original)
        var prepared = false
        let reset = try ConsoleIdentity.reset(save: { stored[$0] = $1 }, generate: { replacement }, prepare: { prepared = $0.deviceId == replacement.deviceId })
        precondition(prepared && reset.resetGeneration != nil && reset.deviceId != legacy.deviceId)
        // Model a stop/cleanup failure after the atomic commit. Old server aliases
        // must never revive the previous key, even if those aliases are corrupt.
        stored["identity." + origin.consoleDigest] = Data("obsolete key entry".utf8)
        stored["identity." + otherOrigin.consoleDigest] = try JSONEncoder().encode(other)
        let resetDefault = try load()
        let resetOldServer = try load(origin)
        let resetOtherServer = try load(otherOrigin)
        precondition(resetDefault.keyRepresentation == replacement.keyRepresentation)
        precondition(resetOldServer.keyRepresentation == replacement.keyRepresentation && resetOtherServer.keyRepresentation == replacement.keyRepresentation)
        let second = ConsoleIdentity(deviceId: "second-replacement", keyRepresentation: Data("second-replacement-key".utf8))
        let resetAgain = try ConsoleIdentity.reset(save: { stored[$0] = $1 }, generate: { second }, prepare: { _ in })
        precondition(resetAgain.resetGeneration != reset.resetGeneration)
        let afterSecondReset = try load(origin)
        precondition(afterSecondReset.deviceId == second.deviceId)

        print("PASS: standalone identity, stable reuse, legacy migration, atomic reset and storage failure handling")
    }
}
