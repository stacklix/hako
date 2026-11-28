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
    var contextUsage: WorkshopContextUsage? = nil

    func hasSameContent(as other: Self) -> Bool {
        eventCursor == other.eventCursor && operationId == other.operationId && historyCursor == other.historyCursor &&
            key == other.key && entries == other.entries && artifacts == other.artifacts && followups == other.followups && streamText == other.streamText && contextUsage == other.contextUsage
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

    static func delayMilliseconds(hasMoreEvents: Bool, failures: Int) -> Int {
        // Buffered event pages must never bypass backoff after a read failure.
        if failures > 0 { return min(15, 1 + failures * 2) * 1000 }
        return hasMoreEvents ? 30 : 1000
    }

    static func catalogNeedsSynchronization(previous: WorkshopSession?, current: WorkshopSession,
                                             operationId: String?, operationActive: Bool, completionId: String?) -> Bool {
        guard previous != current else { return false }
        if current.operationId != operationId { return true }
        let sameActiveOperation = operationActive && current.inProgress && current.operationId == operationId
        let sameCompletion = current.state == "completed" && current.completionId != nil && current.completionId == completionId
        return !sameActiveOperation && !sameCompletion
    }

    static func onEntry(lastVerifiedAt: Date?, now: Date = .now, operationId: String?, observedTerminal: String?,
                        needsRecovery: Bool, busy: Bool) -> Self {
        if busy { return .idle }
        guard let lastVerifiedAt, (0..<60).contains(now.timeIntervalSince(lastVerifiedAt)), !needsRecovery else {
            return .synchronize
        }
        return next(operationId: operationId, observedTerminal: observedTerminal, needsRecovery: false, busy: false)
    }

    static func next(operationId: String?, observedTerminal: String?, needsRecovery: Bool, busy: Bool) -> Self {
        if busy { return .idle }
        // Recovery also runs after a completed operation, or before a new
        // conversation has received its thread/operation identifiers.
        if needsRecovery { return .synchronize }
        if let operationId, observedTerminal != operationId { return .poll(operationId) }
        return .idle
    }
}

struct WorkshopConversationReuseKey: Hashable {
    let scope: String
    let agentId: String
    let applicationId: String
    let sessionId: String
    let archived: Bool
}

struct WorkshopTranscriptPresentation {
    let history: [WorkshopEntry]
    let queued: [WorkshopEntry]
    private static let waitingStates: Set<String> = ["pending", "queued", "paused", "steering", "unknown"]

    static func isQueued(_ entry: WorkshopEntry, state: String? = nil) -> Bool {
        entry.kind == "followup" && waitingStates.contains(state ?? entry.state)
    }

    init(entries: [WorkshopEntry], followups: [WorkshopFollowupState]) {
        var history: [WorkshopEntry] = []
        var queued: [WorkshopEntry] = []
        var agentTurns: Set<String> = []
        for entry in entries where entry.kind != "turn" && entry.kind != "subagentGroup" && !(entry.kind == "plan" && entry.plan?.isEmpty == true) {
            if entry.agents != nil {
                guard let turn = entry.turnId, entry.agents?.isEmpty == false, agentTurns.insert(turn).inserted else { continue }
                history.append(WorkshopEntry(kind: "subagentGroup", id: "agents-" + turn, text: "", role: "", state: "", truncated: false, turnId: turn))
                continue
            }
            let presented: WorkshopEntry
            if entry.kind == "followup", let status = followups.first(where: { $0.id == entry.id }) {
                // Give each row the same resolved state used to place it. A
                // metadata-only acknowledgement must also change the row value.
                presented = WorkshopEntry(kind: entry.kind, id: entry.id, text: entry.text, role: entry.role,
                    state: status.state, truncated: entry.truncated, replacesId: entry.replacesId,
                    questions: entry.questions, questionId: entry.questionId, turnId: entry.turnId,
                    startedAtMs: entry.startedAtMs, completedAtMs: entry.completedAtMs)
            } else { presented = entry }
            if Self.isQueued(presented) { queued.append(presented) }
            else { history.append(presented) }
        }
        self.history = history
        self.queued = queued
    }
}

enum WorkshopArtifactPlacement {
    static func group(_ artifacts: [WorkshopArtifact], entries: [WorkshopEntry], projectPath: String) -> [String: [WorkshopArtifact]] {
        guard !artifacts.isEmpty else { return [:] }
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
    // Preserve item/status boundaries, but concatenate adjacent fragments before
    // searching and replacing the corresponding transcript row.
    static func apply(_ events: [WorkshopEntry], entries: inout [WorkshopEntry], streamText: inout [String: String]) {
        var pending: WorkshopEntry?
        for event in events {
            if var delta = pending, delta.kind == "delta", event.kind == "delta", delta.id == event.id,
               delta.role == event.role, delta.state == event.state, delta.truncated == event.truncated,
               event.replacesId == nil {
                delta.text += event.text
                delta = delta.preservingTiming(from: event)
                pending = delta
            } else {
                if let pending { apply(pending, entries: &entries, streamText: &streamText) }
                pending = event
            }
        }
        if let pending { apply(pending, entries: &entries, streamText: &streamText) }
    }

    static func withoutRecoveredNotices(_ entries: [WorkshopEntry], operationId: String,
                                        state: String, followups: [WorkshopFollowupState]) -> [WorkshopEntry] {
        let known: Set<String> = ["completed", "interrupted", "failed"]
        // Notices keyed by the operation ID describe work in progress (for
        // example context compaction), rather than a permanent transcript item.
        let finished = followups.filter { known.contains($0.state) }.map(\.id)
            + (known.contains(state) ? [operationId] : [])
        let resolved = Set(finished.flatMap { [$0, "error-" + $0] })
        return entries.filter { $0.kind != "notice" || !resolved.contains($0.id) }
    }

    static func history(_ existing: [WorkshopEntry], page: [WorkshopEntry]) -> [WorkshopEntry] {
        let replaced = Set(page.compactMap(\.replacesId))
        var result = existing.filter { !replaced.contains($0.id) }
        var nextID: String?
        for entry in page.reversed() {
            if let index = result.firstIndex(where: { $0.id == entry.id }) {
                // History can lag a live stream; do not shorten an already rendered reply.
                let old = result[index]
                if !(entry.role == "assistant" && old.text.count > entry.text.count && old.text.hasPrefix(entry.text)) {
                    result[index] = entry.preservingTiming(from: old)
                } else { result[index] = old.preservingTiming(from: entry) }
            } else if let nextID, let index = result.firstIndex(where: { $0.id == nextID }) {
                result.insert(entry, at: index)
            } else { result.append(entry) }
            nextID = entry.id
        }
        // Canonical history defines turn order. An optimistic queued message
        // may already exist earlier in the live array; move it forward instead
        // of leaving the next request inside the preceding response.
        var previousID: String?
        for entry in page {
            if let previousID, let previousIndex = result.firstIndex(where: { $0.id == previousID }),
               let index = result.firstIndex(where: { $0.id == entry.id }), index < previousIndex {
                let value = result.remove(at: index)
                if let anchor = result.firstIndex(where: { $0.id == previousID }) { result.insert(value, at: anchor + 1) }
            }
            previousID = entry.id
        }
        return queueAtEnd(result)
    }

    static func apply(_ event: WorkshopEntry, entries: inout [WorkshopEntry], streamText: inout [String: String]) {
        if let replaced = event.replacesId, replaced != event.id {
            entries.removeAll { $0.id == replaced }; streamText[replaced] = nil
        }
        if event.kind == "followup", let old = entries.first(where: { $0.id == event.id }) {
            // Replaying a queue receipt must not downgrade a canonical sent
            // user message or move an already-started request past its reply.
            if old.kind != "followup", old.role == "user" { return }
            if ["starting", "running", "waiting", "finishing", "sent", "completed", "steered"].contains(old.state),
               ["pending", "queued", "paused", "steering"].contains(event.state) { return }
        }
        if event.kind == "followup" && event.state == "cancelled" {
            entries.removeAll { $0.id == event.id }; streamText[event.id] = nil; return
        }
        var entry = event
        let index = entries.last?.id == event.id ? entries.indices.last : entries.firstIndex { $0.id == event.id }
        if event.kind == "delta" {
            let text = (streamText[event.id] ?? "") + event.text
            streamText[event.id] = text
            if let index, entries[index].text.utf8.count > text.utf8.count && entries[index].text.hasPrefix(text) {
                entries[index] = entries[index].preservingTiming(from: event)
                return // A fresh operation replay is catching up with canonical/cached history.
            }
            entry = WorkshopEntry(kind: "item", id: event.id, text: text, role: event.role, state: event.state, truncated: event.truncated,
                turnId: event.turnId, startedAtMs: event.startedAtMs, completedAtMs: event.completedAtMs, turn: event.turn)
        } else if event.role == "assistant" {
            if event.text.isEmpty, let index, !entries[index].text.isEmpty { entry.text = entries[index].text }
            streamText[event.id] = entry.text
        }
        if let index {
            entry = entry.preservingTiming(from: entries[index])
            if WorkshopTranscriptPresentation.isQueued(entries[index]), !WorkshopTranscriptPresentation.isQueued(entry) {
                entries.remove(at: index)
                entries = queueAtEnd(entries)
                let tail = entries.firstIndex(where: { WorkshopTranscriptPresentation.isQueued($0) }) ?? entries.endIndex
                entries.insert(entry, at: tail)
            } else { entries[index] = entry }
        } else if !WorkshopTranscriptPresentation.isQueued(entry),
                  let tail = entries.firstIndex(where: { WorkshopTranscriptPresentation.isQueued($0) }) {
            entries.insert(entry, at: tail)
        } else {
            entries.append(entry)
        }
        if entry.kind == "followup" { entries = queueAtEnd(entries) }
    }

    private static func queueAtEnd(_ entries: [WorkshopEntry]) -> [WorkshopEntry] {
        // Reorder raw records only. Presentation synthesizes agent anchors and
        // hides turn boundaries; writing it back would destroy source metadata.
        entries.filter { !WorkshopTranscriptPresentation.isQueued($0) }
            + entries.filter { WorkshopTranscriptPresentation.isQueued($0) }
    }
}

// Only the newest waiting snapshot for each file is retained. Reading never
// blocks the caller; pending snapshots also provide read-your-writes semantics.
final class WorkshopTranscriptDisk: @unchecked Sendable {
    struct Removal: Sendable { var removed: [WorkshopTranscript]; var retained: [WorkshopTranscript] }
    private struct Pending { let url: URL; let snapshot: WorkshopTranscript; let order: Int }
    private let queue = DispatchQueue(label: "me.stackli.hako.workshop.transcripts", qos: .utility)
    private let readQueue = DispatchQueue(label: "me.stackli.hako.workshop.transcripts.read", qos: .userInitiated, attributes: .concurrent)
    private let lock = NSLock()
    private var pending: [URL: Pending] = [:]
    private var writing: [URL: WorkshopTranscript] = [:]
    private var archivedSessions: Set<String> = []
    private var scheduled = false
    private var generation = 0
    private var order = 0
    private let delay: TimeInterval
    private let writeFile: @Sendable (WorkshopTranscript, URL) throws -> Void
    private let maxFiles = 50
    private let maxBytes = 64 * 1024 * 1024

    init(delay: TimeInterval = 0.25,
         writeFile: @escaping @Sendable (WorkshopTranscript, URL) throws -> Void = { try WorkshopTranscriptDisk.save($0, to: $1) }) {
        self.delay = delay
        self.writeFile = writeFile
    }

    private func latest(_ url: URL) -> WorkshopTranscript? {
        lock.lock(); defer { lock.unlock() }
        return pending[url]?.snapshot ?? writing[url]
    }

    private func session(_ key: WorkshopTranscriptKey, in directory: URL) -> String { directory.path + "\n" + key.agentId + "\n" + key.threadId }
    private func permits(_ key: WorkshopTranscriptKey, at file: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !archivedSessions.contains(session(key, in: file.deletingLastPathComponent()))
    }
    func allow(_ key: WorkshopTranscriptKey, in directory: URL) {
        lock.lock(); archivedSessions.remove(session(key, in: directory)); lock.unlock()
    }

    private func blockSession(_ identity: String) -> Removal {
        lock.lock()
        defer { lock.unlock() }
        archivedSessions.insert(identity)
        let waiting = pending.values.filter { session($0.snapshot.key, in: $0.url.deletingLastPathComponent()) == identity }.map(\.snapshot)
        let retained = pending.values.filter { session($0.snapshot.key, in: $0.url.deletingLastPathComponent()) != identity }.map(\.snapshot)
        pending = pending.filter { session($0.value.snapshot.key, in: $0.value.url.deletingLastPathComponent()) != identity }
        return Removal(removed: waiting, retained: retained)
    }
    func removeSession(agentID: String, threadID: String, in directory: URL) async throws -> Removal {
        let waiting = blockSession(directory.path + "\n" + agentID + "\n" + threadID)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    var snapshots = waiting
                    let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
                    for file in files where file.pathExtension == "json" && file.deletingPathExtension().lastPathComponent.count == 64 {
                        guard let snapshot = Self.load(file) else { continue }
                        if snapshot.key.agentId == agentID && snapshot.key.threadId == threadID {
                            snapshots.removed.append(snapshot)
                            try FileManager.default.removeItem(at: file)
                        } else { snapshots.retained.append(snapshot) }
                    }
                    continuation.resume(returning: snapshots)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func read(_ url: URL, key: WorkshopTranscriptKey) async -> WorkshopTranscript? {
        guard permits(key, at: url) else { return nil }
        if let snapshot = latest(url) { return snapshot.key == key && snapshot.eventCursor >= 0 ? snapshot : nil }
        return await withCheckedContinuation { continuation in
            readQueue.async {
                let snapshot = self.latest(url) ?? Self.load(url)
                continuation.resume(returning: snapshot.flatMap { self.permits(key, at: url) && $0.key == key && $0.eventCursor >= 0 ? $0 : nil })
            }
        }
    }

    func write(_ snapshot: WorkshopTranscript, to url: URL) {
        lock.lock()
        guard !archivedSessions.contains(session(snapshot.key, in: url.deletingLastPathComponent())) else { lock.unlock(); return }
        order += 1
        pending[url] = Pending(url: url, snapshot: snapshot, order: order)
        guard !scheduled else { lock.unlock(); return }
        scheduled = true
        let expected = generation
        lock.unlock()
        queue.asyncAfter(deadline: .now() + delay) { self.drain(expected: expected) }
    }

    func flush() async {
        await withCheckedContinuation { continuation in
            queue.async { self.drain(); continuation.resume() }
        }
    }

    private func drain(expected: Int? = nil) {
        lock.lock()
        guard expected == nil || expected == generation else { lock.unlock(); return }
        generation += 1
        let batch = pending.values.sorted { $0.order < $1.order }
        pending.removeAll(); writing = Dictionary(uniqueKeysWithValues: batch.map { ($0.url, $0.snapshot) }); scheduled = false
        lock.unlock()
        var directories: [URL: URL] = [:]
        for value in batch {
            do { try writeFile(value.snapshot, value.url); directories[value.url.deletingLastPathComponent()] = value.url }
            catch { /* This optional cache must not interrupt message delivery. */ }
        }
        for (directory, current) in directories { prune(directory, keeping: current) }
        lock.lock(); writing.removeAll(); lock.unlock()
    }

    private static func load(_ url: URL) -> WorkshopTranscript? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2 * 1024 * 1024,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WorkshopTranscript.self, from: data)
    }

    private static func save(_ snapshot: WorkshopTranscript, to url: URL) throws {
        guard let bytes = try snapshot.encodedForCache() else { return }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        try bytes.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try bytes.write(to: url, options: .atomic)
        #endif
        #if os(iOS) || os(macOS)
        var directoryURL = directory
        var flags = URLResourceValues(); flags.isExcludedFromBackup = false
        try directoryURL.setResourceValues(flags)
        var file = url
        flags.isExcludedFromBackup = true
        try file.setResourceValues(flags)
        #endif
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
