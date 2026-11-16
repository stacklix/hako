import Foundation

struct WorkshopComposerText: Equatable {
    private(set) var text = ""
    private(set) var editorID = UUID()

    mutating func update(_ text: String, editorID: UUID) {
        guard self.editorID == editorID else { return }
        self.text = text
    }

    mutating func clearAfterSending() { self = WorkshopComposerText() }
}

#if canImport(Combine)
import Combine

@MainActor final class WorkshopComposerInput: ObservableObject {
    @Published private var value = WorkshopComposerText()
    var text: String {
        get { value.text }
        set { updateText(newValue, editorID: editorID) }
    }
    var editorID: UUID { value.editorID }
    var snapshot: WorkshopComposerText { value }
    var onChange: (() -> Void)?

    func updateText(_ value: String, editorID: UUID) {
        var next = self.value
        next.update(value, editorID: editorID)
        guard next != self.value else { return }
        self.value = next
        onChange?()
    }

    func clearAfterSending() {
        // Publish the empty value and its new identity together. An old editor
        // cannot observe a new identity paired with the previously sent text.
        var next = value
        next.clearAfterSending()
        value = next
        onChange?()
    }
}
#endif

struct WorkshopDraftInput: Codable, Equatable, Sendable {
    var text: String
    var imageIds: [String]
}

struct WorkshopComposerDraft: Codable, Equatable, Sendable {
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

// All writes are ordered on one queue. A short, bounded window coalesces typing
// without postponing persistence indefinitely during continuous input.
final class WorkshopDraftWriter: @unchecked Sendable {
    private struct Pending {
        var draft: WorkshopComposerDraft
        var obsolete: Set<URL>
        var completion: @Sendable (Result<Void, Error>) -> Void
    }

    private let queue = DispatchQueue(label: "me.stackli.hako.workshop.drafts", qos: .utility)
    private let delay: TimeInterval
    private let writeFile: @Sendable (WorkshopComposerDraft, URL) throws -> Void
    private var pending: [URL: Pending] = [:]
    private var scheduled = false
    private var generation = 0

    init(delay: TimeInterval = 0.25,
         writeFile: @escaping @Sendable (WorkshopComposerDraft, URL) throws -> Void = { try WorkshopDraftDisk.write($0, to: $1) }) {
        self.delay = delay
        self.writeFile = writeFile
    }

    func write(_ draft: WorkshopComposerDraft, to file: URL, removing previous: URL? = nil,
               completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        queue.async {
            // A new composer can reuse an old key before migration is flushed.
            // Its newer input must survive the older migration's cleanup.
            for key in Array(self.pending.keys) where key != file {
                self.pending[key]?.obsolete.remove(file)
            }
            var obsolete = self.pending[file]?.obsolete ?? []
            if let previous, previous != file {
                obsolete.formUnion(self.pending.removeValue(forKey: previous)?.obsolete ?? [])
                obsolete.insert(previous)
            }
            obsolete.remove(file)
            self.pending[file] = Pending(draft: draft, obsolete: obsolete, completion: completion)
            guard !self.scheduled else { return }
            self.scheduled = true
            let generation = self.generation
            self.queue.asyncAfter(deadline: .now() + self.delay) {
                guard self.generation == generation else { return }
                self.drain()
            }
        }
    }

    func flush() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.drain()
                continuation.resume()
            }
        }
    }

    private func drain() {
        generation += 1
        scheduled = false
        let writes = pending
        pending.removeAll()
        for (file, value) in writes {
            do {
                try writeFile(value.draft, file)
                // Remove old session keys only after their replacement is saved.
                for previous in value.obsolete {
                    try writeFile(WorkshopComposerDraft(input: WorkshopDraftInput(text: "", imageIds: [])), previous)
                }
                value.completion(.success(()))
            } catch {
                // Keep failed migrations and their cleanup keys for the next
                // explicit flush or edit instead of resurrecting an old draft.
                pending[file] = value
                value.completion(.failure(error))
            }
        }
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
