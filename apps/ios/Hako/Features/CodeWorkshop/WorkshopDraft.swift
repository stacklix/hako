import Foundation

struct WorkshopDraftInput: Codable, Equatable {
    var text: String
    var imageIds: [String]
}

struct WorkshopComposerDraft: Codable, Equatable {
    var input: WorkshopDraftInput
    var editingMessageID: String?
    var originalInput: WorkshopDraftInput?
    var sendingMessageID: String?

    var isEmpty: Bool {
        input.text.isEmpty && input.imageIds.isEmpty && editingMessageID == nil && originalInput == nil
    }

    var hasUnsentInput: Bool {
        guard sendingMessageID == nil else { return false }
        return !input.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !input.imageIds.isEmpty
            || originalInput.map { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !$0.imageIds.isEmpty } == true
    }

    func matchesSentMessage(_ text: String, imageIds: [String], id: String) -> Bool {
        sendingMessageID == id && editingMessageID == nil && input.text.trimmingCharacters(in: .whitespacesAndNewlines) == text
            && input.imageIds == imageIds
    }
}

enum WorkshopDraftDisk {
    static func read(_ file: URL) throws -> WorkshopComposerDraft? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(WorkshopComposerDraft.self, from: Data(contentsOf: file))
    }

    static func write(_ draft: WorkshopComposerDraft, to file: URL) throws {
        if draft.isEmpty {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            return
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(draft)
        #if os(iOS)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: file, options: .atomic)
        #endif
        var url = file
        var flags = URLResourceValues(); flags.isExcludedFromBackup = true
        try url.setResourceValues(flags)
    }
}
