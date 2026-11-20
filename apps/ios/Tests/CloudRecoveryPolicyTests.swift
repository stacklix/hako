import Foundation

@main struct CloudRecoveryPolicyTests {
    static func main() throws {
        let scopes = WorkshopBackup.scopes + InvestmentBackup.scopes + QinglongBackup.scopes
            + [HakoBackupScope(root: "HakoLogs", requiresHistory: true), HakoBackupScope(root: "ShortcutHistory", requiresHistory: true)]
        let key = "hako.appearance"
        let now = Date(timeIntervalSince1970: 100)
        var state = CloudPreferenceState()
        state.observe([key: .text("dark")], now: now, writer: "phone-a", seedMissing: true)
        precondition(state.records[key]?.isSeed == true)
        let laterSeed = CloudPreferenceRecord(key: key, value: .text("system"), modifiedAt: Date(timeIntervalSince1970: -200), writer: "phone-z")
        precondition(state.merge([key: laterSeed]).isEmpty, "A later installation's defaults replaced an earlier seed")
        var fresh = CloudPreferenceState()
        fresh.observe([key: .text("dark")], now: now, writer: "phone-a")
        precondition(fresh.records[key]?.modifiedAt == now, "A deliberate new preference was treated as an old seed")
        let remote = CloudPreferenceRecord(key: key, value: .text("light"), modifiedAt: Date(timeIntervalSince1970: 50), writer: "phone-b")
        precondition(state.merge([key: remote]).count == 1, "First download must win over old local defaults")
        precondition(state.records[key]?.value == .text("light"))
        state.observe([key: .text("system")], now: now, writer: "phone-a")
        precondition(state.merge([key: remote]).isEmpty, "Stale cloud value overwrote a local edit")
        let tombstone = CloudPreferenceRecord(key: key, value: nil, modifiedAt: now.addingTimeInterval(10), writer: "phone-b")
        precondition(state.merge([key: tombstone]).count == 1)
        state.observe([:], now: now.addingTimeInterval(20), writer: "phone-a")
        precondition(state.records[key] == tombstone, "A deleted preference was resurrected")
        state.observe([key: .text("dark")], now: now, writer: "phone-a")
        precondition(state.records[key]!.modifiedAt > tombstone.modifiedAt, "Clock rollback lost a deliberate edit")
        let wrongType = CloudPreferenceRecord(key: key, value: .bytes(Data([1])), modifiedAt: .distantFuture, writer: "bad")
        precondition(state.merge([key: wrongType]).isEmpty)
        let wrongKey = CloudPreferenceRecord(key: "console.session", value: .text("private"), modifiedAt: .distantFuture, writer: "bad")
        precondition(state.merge(["console.session": wrongKey]).isEmpty)
        precondition(!CloudPreferenceState.allowedKeys.contains("arcane.pending"))
        precondition(!CloudPreferenceState.allowedKeys.contains("hako.deviceMonitor.lastAgents"))
        precondition(!CloudPreferenceState.allowedKeys.contains("hako.icloud.includeHistory"))
        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(CloudPreferenceState.self, from: encoded)
        precondition(decoded.records == state.records)

        precondition(HakoBackupPolicy.included("CodeWorkshop/messages-account/hash.draft.json", directory: false, history: false, scopes: scopes))
        precondition(HakoBackupPolicy.included("CodeWorkshop/account.instructions.txt", directory: false, history: false, scopes: scopes))
        precondition(!HakoBackupPolicy.included("CodeWorkshop/messages-account/hash.json", directory: false, history: true, scopes: scopes))
        precondition(HakoBackupPolicy.included("CodeWorkshop/messages-account", directory: true, history: false, scopes: scopes))
        precondition(HakoBackupPolicy.included("WorkshopCommands/account.prompts.json", directory: false, history: false, scopes: scopes))
        precondition(!HakoBackupPolicy.included("WorkshopCommands/account.json", directory: false, history: true, scopes: scopes))
        precondition(HakoBackupPolicy.included("InvestmentAgent/account.plist.draft", directory: false, history: false, scopes: scopes))
        precondition(HakoBackupPolicy.included("QinglongAssistant/account.plist", directory: false, history: false, scopes: scopes))
        precondition(!HakoBackupPolicy.included("Hako/InvestmentCache/account.json", directory: false, history: true, scopes: scopes))
        for root in ["ShortcutHistory", "HakoLogs"] {
            precondition(!HakoBackupPolicy.included(root + "/events.json", directory: false, history: false, scopes: scopes))
            precondition(HakoBackupPolicy.included(root + "/events.json", directory: false, history: true, scopes: scopes))
        }
        #if canImport(Darwin)
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("CodeWorkshop/messages-example")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let draft = folder.appendingPathComponent("example.draft.json"), cache = folder.appendingPathComponent("example.json")
        try Data("draft".utf8).write(to: draft)
        try Data("cache".utf8).write(to: cache)
        var excluded = folder; var flags = URLResourceValues(); flags.isExcludedFromBackup = true
        try excluded.setResourceValues(flags)
        try HakoBackupPolicy.prepareExistingFiles(at: base, history: false, scopes: scopes)
        // The policy writes through different URL instances. Darwin caches resource
        // values on each URL, so discard the fixture's old exclusion before reading.
        func isExcluded(_ file: URL) throws -> Bool? {
            var file = file
            file.removeAllCachedResourceValues()
            return try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        }
        let folderExcluded = try isExcluded(folder), draftExcluded = try isExcluded(draft), cacheExcluded = try isExcluded(cache)
        precondition(folderExcluded == false, "Draft folder remains excluded: \(String(describing: folderExcluded))")
        precondition(draftExcluded == false, "Draft remains excluded: \(String(describing: draftExcluded))")
        precondition(cacheExcluded == true, "Downloadable cache was included: \(String(describing: cacheExcluded))")
        #endif
        print("PASS: preference reconciliation, initial download, offline changes, deletion, type validation and backup boundaries")
    }
}
