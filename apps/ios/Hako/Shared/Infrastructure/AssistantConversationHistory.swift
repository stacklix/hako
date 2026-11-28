import Foundation

/// Archives are owned by the existing account/ledger or panel-specific conversation URL.
actor AssistantConversationHistory {
    static let shared = AssistantConversationHistory()

    struct Entry: Codable, Hashable, Identifiable, Sendable {
        let id: UUID
        let title: String
        let preview: String
        let updatedAt: Date
    }

    struct Snapshot: Codable, Sendable {
        let entry: Entry
        let conversation: Data
        let tools: Data?
        let draft: Data?

        func validate<Conversation: Decodable, Tool: Decodable>(conversation: Conversation.Type, tool: Tool.Type) throws {
            let decoder = PropertyListDecoder()
            _ = try decoder.decode(conversation, from: self.conversation)
            if let tools { _ = try decoder.decode([Tool].self, from: tools) }
            if let draft { _ = try decoder.decode(AssistantComposerDraft.self, from: draft) }
        }
    }

    private struct Identity: Codable { let id: UUID }

    private func directory(_ current: URL) -> URL { current.appendingPathExtension("history") }
    private func identity(_ current: URL) -> URL { current.appendingPathExtension("identity") }
    private func folder(_ id: UUID, current: URL) -> URL {
        directory(current).appendingPathComponent(id.uuidString, isDirectory: true)
    }

    @discardableResult
    func save(current: URL, title: String, preview: String) throws -> Entry {
        let id = try read(Identity.self, from: identity(current))?.id ?? UUID()
        let entry = Entry(id: id, title: String(title.prefix(120)), preview: String(preview.prefix(180)), updatedAt: .now)
        let snapshot = Snapshot(entry: entry, conversation: try Data(contentsOf: current),
                                tools: try data(current.appendingPathExtension("tools")),
                                draft: try data(current.appendingPathExtension("draft")))
        let target = folder(id, current: current)
        // Keep a recoverable complete bundle before changing the active files.
        try write(snapshot, to: target.appendingPathComponent("snapshot.plist"))
        try write(entry, to: target.appendingPathComponent("metadata.plist"))
        try write(Identity(id: id), to: identity(current))
        return entry
    }

    func list(current: URL) throws -> [Entry] {
        let urls: [URL]
        do { urls = try FileManager.default.contentsOfDirectory(at: directory(current), includingPropertiesForKeys: nil) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
        return try urls.compactMap { url -> Entry? in
            guard let id = UUID(uuidString: url.lastPathComponent) else { return nil }
            let entry = try read(Entry.self, from: url.appendingPathComponent("metadata.plist"))
            guard entry?.id == id else { throw CocoaError(.coderReadCorrupt) }
            return entry
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func load(_ id: UUID, current: URL) throws -> Snapshot {
        guard let snapshot = try read(Snapshot.self, from: folder(id, current: current).appendingPathComponent("snapshot.plist")),
              snapshot.entry.id == id else { throw CocoaError(.coderReadCorrupt) }
        return snapshot
    }

    func isActive(_ id: UUID, current: URL) throws -> Bool {
        try read(Identity.self, from: identity(current))?.id == id
    }

    func activate(_ snapshot: Snapshot, current: URL) throws {
        // Roll back active files on a partial write; both sessions are already archived.
        let urls = [current.appendingPathExtension("tools"), current.appendingPathExtension("draft"), current, identity(current)]
        let previous = try urls.map { try data($0) }
        do {
            try replace(snapshot.tools, at: urls[0])
            try replace(snapshot.draft, at: urls[1])
            try replace(snapshot.conversation, at: current)
            try write(Identity(id: snapshot.entry.id), to: identity(current))
        } catch {
            let failure = error
            for (url, bytes) in zip(urls, previous) { try? replace(bytes, at: url) }
            throw failure
        }
    }

    func reset(current: URL) throws {
        for url in [current.appendingPathExtension("tools"), current.appendingPathExtension("draft"), current, identity(current)] {
            try replace(nil, at: url)
        }
    }

    private func read<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value? {
        try data(url).map { try PropertyListDecoder().decode(type, from: $0) }
    }

    private func data(_ url: URL) throws -> Data? {
        do { return try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }

    private func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        try replace(try encoder.encode(value), at: url)
    }

    private func replace(_ bytes: Data?, at url: URL) throws {
        guard let bytes else {
            do { try FileManager.default.removeItem(at: url) }
            catch let error as CocoaError where error.code == .fileNoSuchFile {}
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try bytes.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try bytes.write(to: url, options: .atomic)
        #endif
    }
}
