import Foundation

struct WorkshopTranscriptKey: Codable, Equatable, Sendable {
    let agentId: String
    let applicationId: String
    let threadId: String
}

struct WorkshopTranscript: Codable, Equatable, Sendable {
    let key: WorkshopTranscriptKey
    var entries: [WorkshopEntry]
    var artifacts: [WorkshopArtifact]
    var followups: [WorkshopFollowupState]
    var historyCursor: String?
    var operationId: String?
    var eventCursor: Int64
    var streamText: [String: String]
    var savedAt: Date

    func hasSameContent(as other: Self) -> Bool {
        key == other.key && entries == other.entries && artifacts == other.artifacts && followups == other.followups &&
            historyCursor == other.historyCursor && operationId == other.operationId && eventCursor == other.eventCursor && streamText == other.streamText
    }

    func encodedForCache(maxEntries: Int = 300, maxBytes: Int = 2 * 1024 * 1024) throws -> Data? {
        var snapshot = self
        if snapshot.entries.count > maxEntries {
            snapshot.entries = Array(snapshot.entries.suffix(maxEntries))
            snapshot.historyCursor = nil
        }
        let encoder = JSONEncoder()
        var bytes = try encoder.encode(snapshot)
        if bytes.count > maxBytes && !snapshot.streamText.isEmpty {
            // A cursor can only resume text whose accumulator is in the same atomic snapshot.
            snapshot.streamText = [:]; snapshot.eventCursor = 0
            bytes = try encoder.encode(snapshot)
        }
        while bytes.count > maxBytes && !snapshot.entries.isEmpty {
            snapshot.entries.removeFirst(min(10, snapshot.entries.count))
            snapshot.historyCursor = nil
            bytes = try encoder.encode(snapshot)
        }
        return bytes.count <= maxBytes ? bytes : nil
    }
}

enum WorkshopWatchStep: Equatable {
    case synchronize, poll(String), idle

    static func next(operationId: String?, observedTerminal: String?, needsRecovery: Bool, busy: Bool) -> Self {
        if busy { return .idle }
        // Recovery also runs after a completed operation, or before a new
        // conversation has received its thread/operation identifiers.
        if needsRecovery { return .synchronize }
        if let operationId, observedTerminal != operationId { return .poll(operationId) }
        return .idle
    }
}

struct WorkshopScrollFollowing {
    private(set) var followsBottom = true
    private var manualScroll = false
    private var nearBottom = true

    mutating func observe(nearBottom: Bool) {
        self.nearBottom = nearBottom
        // Content can grow before its scroll anchor is applied. Only a user's
        // scroll away from the bottom should turn off response following.
        if manualScroll || nearBottom { followsBottom = nearBottom }
    }

    mutating func interacting(_ active: Bool) {
        if active { manualScroll = true }
        else if manualScroll {
            followsBottom = nearBottom
            manualScroll = false
        }
    }
}

struct WorkshopTranscriptPresentation {
    let history: [WorkshopEntry]
    let queued: [WorkshopEntry]

    init(entries: [WorkshopEntry], followups: [WorkshopFollowupState]) {
        var history: [WorkshopEntry] = []
        var queued: [WorkshopEntry] = []
        let waitingStates: Set<String> = ["pending", "queued", "paused", "steering", "unknown"]
        for entry in entries {
            let state = followups.first { $0.id == entry.id }?.state ?? entry.state
            if entry.kind == "followup", waitingStates.contains(state) { queued.append(entry) }
            else { history.append(entry) }
        }
        self.history = history
        self.queued = queued
    }
}

enum WorkshopArtifactPlacement {
    static func group(_ artifacts: [WorkshopArtifact], entries: [WorkshopEntry], projectPath: String) -> [String: [WorkshopArtifact]] {
        let project = normalize(projectPath).trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/"
        let candidates = entries.filter { $0.role == "assistant" || $0.kind == "fileChange" }
            .map { (entry: $0, text: normalize($0.text)) }
        var result: [String: [WorkshopArtifact]] = [:]
        for artifact in artifacts {
            let path = normalize(artifact.path)
            var paths = [path]
            if path.hasPrefix(project) { paths.append(String(path.dropFirst(project.count))) }
            if path.count > 2, path[path.index(after: path.startIndex)] == ":" { paths.append("/" + path) }
            // Match complete paths, not a basename shared by unrelated prototypes.
            let pattern = "(?<![\\p{L}\\p{N}_./:-])(?:" + paths.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + ")(?![\\p{L}\\p{N}_./-])"
            let matches = candidates.filter { $0.text.range(of: pattern, options: .regularExpression) != nil }
            // Prefer the delivered reply over the earlier file-change record.
            if let owner = matches.first(where: { $0.entry.role == "assistant" }) ?? matches.first {
                result[owner.entry.id, default: []].append(artifact)
            }
        }
        return result
    }

    private static func normalize(_ text: String) -> String {
        (text.removingPercentEncoding ?? text)
            .replacingOccurrences(of: "\\\\", with: "\\")
            .replacingOccurrences(of: "\\", with: "/").lowercased()
    }
}

enum WorkshopTranscriptMerge {
    static func history(_ existing: [WorkshopEntry], page: [WorkshopEntry]) -> [WorkshopEntry] {
        let replaced = Set(page.compactMap(\.replacesId))
        var result = existing.filter { !replaced.contains($0.id) }
        var nextID: String?
        for entry in page.reversed() {
            if let index = result.firstIndex(where: { $0.id == entry.id }) {
                // History can lag a live stream; do not shorten an already rendered reply.
                let old = result[index]
                if !(entry.role == "assistant" && old.text.count > entry.text.count && old.text.hasPrefix(entry.text)) {
                    result[index] = entry
                }
            } else if let nextID, let index = result.firstIndex(where: { $0.id == nextID }) {
                result.insert(entry, at: index)
            } else { result.append(entry) }
            nextID = entry.id
        }
        return result
    }

    static func apply(_ event: WorkshopEntry, entries: inout [WorkshopEntry], streamText: inout [String: String]) {
        if let replaced = event.replacesId, replaced != event.id {
            entries.removeAll { $0.id == replaced }; streamText[replaced] = nil
        }
        if event.kind == "followup" && event.state == "cancelled" {
            entries.removeAll { $0.id == event.id }; streamText[event.id] = nil; return
        }
        var entry = event
        if event.kind == "delta" {
            let text = (streamText[event.id] ?? "") + event.text
            streamText[event.id] = text
            if let old = entries.first(where: { $0.id == event.id }), old.text.count > text.count && old.text.hasPrefix(text) {
                return // A fresh operation replay is catching up with canonical/cached history.
            }
            entry = WorkshopEntry(kind: "item", id: event.id, text: text, role: event.role, state: event.state, truncated: event.truncated)
        } else if event.role == "assistant" {
            streamText[event.id] = event.text
            if event.text.isEmpty, entries.contains(where: { $0.id == event.id && !$0.text.isEmpty }) { return }
        }
        if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index] = entry }
        else { entries.append(entry) }
    }
}

// Cache I/O is serialized off the UI thread. Reads wait for earlier writes to finish.
final class WorkshopTranscriptDisk: @unchecked Sendable {
    private let queue = DispatchQueue(label: "me.stackli.hako.workshop.transcripts", qos: .utility)
    private let maxFiles = 50
    private let maxBytes = 64 * 1024 * 1024

    func read(_ url: URL, key: WorkshopTranscriptKey) -> WorkshopTranscript? {
        queue.sync {
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2 * 1024 * 1024,
                  let data = try? Data(contentsOf: url), let snapshot = try? JSONDecoder().decode(WorkshopTranscript.self, from: data),
                  snapshot.key == key, snapshot.eventCursor >= 0 else { return nil }
            return snapshot
        }
    }

    func write(_ snapshot: WorkshopTranscript, to url: URL) {
        queue.async { [self] in
            guard let bytes = try? snapshot.encodedForCache() else { return }
            do {
                let directory = url.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                #if os(iOS)
                try bytes.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                #else
                try bytes.write(to: url, options: .atomic)
                #endif
                #if os(iOS) || os(macOS)
                var directoryURL = directory
                var flags = URLResourceValues(); flags.isExcludedFromBackup = true
                try directoryURL.setResourceValues(flags)
                #endif
                prune(directory, keeping: url)
            } catch { /* An optional cache must not interrupt message delivery. */ }
        }
    }

    private func prune(_ directory: URL, keeping current: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]) else { return }
        let candidates = files.compactMap { url -> (URL, Date, Int)? in
            guard url.pathExtension == "json", url.deletingPathExtension().lastPathComponent.count == 64,
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }.sorted { $0.1 > $1.1 }
        var count = 1
        var size = candidates.first(where: { $0.0 == current })?.2 ?? 0
        for (url, _, bytes) in candidates {
            if url == current { continue }
            if count + 1 > maxFiles || size + bytes > maxBytes { try? FileManager.default.removeItem(at: url) }
            else { count += 1; size += bytes }
        }
    }
}
