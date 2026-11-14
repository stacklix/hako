import Foundation

struct AssistantConversationFiles<Conversation: Codable, Tool: Codable> {
    let url: URL

    func load() throws -> Conversation? {
        do { return try PropertyListDecoder().decode(Conversation.self, from: Data(contentsOf: url)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }

    func save(_ conversation: Conversation) throws {
        try Self.write(conversation, to: url)
    }

    // Composer drafts have their own file, leaving saved conversation snapshots unchanged.
    private var composerURL: URL { url.appendingPathExtension("draft") }
    private var toolsURL: URL { url.appendingPathExtension("tools") }

    func loadToolCalls() throws -> [Tool] {
        do { return try PropertyListDecoder().decode([Tool].self, from: Data(contentsOf: toolsURL)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
    }

    func saveToolCalls(_ records: [Tool]) throws {
        if records.isEmpty { try Self.remove(toolsURL) }
        else { try Self.write(records, to: toolsURL) }
    }

    func loadComposerDraft() throws -> AssistantComposerDraft {
        do { return try PropertyListDecoder().decode(AssistantComposerDraft.self, from: Data(contentsOf: composerURL)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return .init() }
    }

    func saveComposerDraft(_ draft: AssistantComposerDraft) throws {
        if draft.isEmpty { try Self.remove(composerURL) }
        else { try Self.write(draft, to: composerURL) }
    }

    private static func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        var directory = url.deletingLastPathComponent()
        let files = FileManager.default
        if !files.fileExists(atPath: directory.path) {
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        #if os(iOS)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        let options: Data.WritingOptions = .atomic
        #endif
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(value).write(to: url, options: options)
    }

    func remove() throws {
        try Self.remove(composerURL)
        try Self.remove(toolsURL)
        try Self.remove(url)
    }

    private static func remove(_ url: URL) throws {
        do { try FileManager.default.removeItem(at: url) }
        catch let error as CocoaError where error.code == .fileNoSuchFile {}
    }
}
