import Foundation

struct WorkshopEntryGroup: Identifiable, Equatable, Sendable {
    var entries: [WorkshopEntry]
    var id: String { entries[0].id }
    var isRecords: Bool { Self.isRecord(entries[0]) }

    static func group(_ entries: [WorkshopEntry], artifactsAfter: Set<String>) -> [Self] {
        var groups: [Self] = []
        for entry in entries {
            if isRecord(entry), let last = groups.last, last.isRecords,
               !artifactsAfter.contains(last.entries.last!.id) {
                groups[groups.count - 1].entries.append(entry)
            } else { groups.append(Self(entries: [entry])) }
        }
        return groups
    }

    private static func isRecord(_ entry: WorkshopEntry) -> Bool {
        entry.role != "user" && entry.role != "assistant" && entry.kind != "notice" && entry.kind != "followup"
    }
}

struct WorkshopTranscriptLayout: Sendable {
    var revision = 0
    var groups: [WorkshopEntryGroup] = []
    var queued: [WorkshopEntry] = []
    var artifactsByEntry: [String: [WorkshopArtifact]] = [:]
    var messageParts: [String: [WorkshopMessagePart]] = [:]
    var questionReplies: [String: [WorkshopQuestionReply]] = [:]
    var turnFooters: [String: WorkshopTurn] = [:]
    var isEmpty: Bool { groups.isEmpty && queued.isEmpty }

    // Local history is visible before Markdown and artifact parsing finishes.
    static func initial(entries: [WorkshopEntry], followups: [WorkshopFollowupState], revision: Int) -> Self {
        let transcript = WorkshopTranscriptPresentation(entries: entries, followups: followups)
        let text = Dictionary(transcript.history.filter { $0.role == "assistant" && $0.kind != "imageGeneration" }
            .map { ($0.id, [WorkshopMessagePart.text($0.text)]) }, uniquingKeysWith: { _, latest in latest })
        return Self(revision: revision, groups: WorkshopEntryGroup.group(transcript.history, artifactsAfter: []),
            queued: transcript.queued, messageParts: text, turnFooters: WorkshopTurn.footers(in: entries))
    }

    func canReplace(_ current: Self, latestRevision: Int) -> Bool {
        revision == latestRevision || !isEmpty || current.isEmpty
    }

    func containsMessage(_ id: String) -> Bool {
        let matches: (WorkshopEntry) -> Bool = { $0.id == id || $0.replacesId == id }
        return queued.contains(where: matches) || groups.contains { $0.entries.contains(where: matches) }
    }
}

// One renderer per retained conversation. The actor serializes cache mutations;
// unchanged messages are neither reparsed nor searched for artifact paths again.
actor WorkshopTranscriptRenderer {
    private struct Parsed { let text: String; let parts: [WorkshopMessagePart] }
    private struct Matched { let text: String; let artifacts: Set<String> }
    private var parsed: [String: Parsed] = [:]
    private var matched: [String: Matched] = [:]
    private var patterns: [String: NSRegularExpression] = [:]
    private var artifactPaths: [String: String] = [:]
    private var project = ""
    private let parseMessage: @Sendable (String) -> [WorkshopMessagePart]

    init(parseMessage: @escaping @Sendable (String) -> [WorkshopMessagePart] = { WorkshopMessage.parts($0) }) {
        self.parseMessage = parseMessage
    }

    func render(entries: [WorkshopEntry], followups: [WorkshopFollowupState], artifacts: [WorkshopArtifact],
                projectPath: String, revision: Int) -> WorkshopTranscriptLayout {
        let presentation = WorkshopTranscriptPresentation(entries: entries, followups: followups)
        let questions = Dictionary(entries.compactMap { entry in
            entry.questions.map { (entry.id, $0) }
        }, uniquingKeysWith: { _, latest in latest })
        var questionReplies: [String: [WorkshopQuestionReply]] = [:]
        for entry in presentation.history + presentation.queued where entry.role == "user" {
            if let questionId = entry.questionId, let source = questions[questionId],
               let replies = WorkshopAsyncQuestion.replySections(in: entry.text, questions: source) {
                questionReplies[entry.id] = replies
            }
        }
        let paths = Dictionary(artifacts.map { ($0.id, $0.path) }, uniquingKeysWith: { _, last in last })
        if project != projectPath || paths != artifactPaths {
            project = projectPath; artifactPaths = paths; matched.removeAll()
            let root = Self.normalize(projectPath).trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/"
            patterns = paths.compactMapValues { path in
                let path = Self.normalize(path)
                var candidates = [path]
                if path.hasPrefix(root) { candidates.append(String(path.dropFirst(root.count))) }
                if path.count > 2, path[path.index(after: path.startIndex)] == ":" { candidates.append("/" + path) }
                let pattern = "(?<![\\p{L}\\p{N}_./:-])(?:" + candidates.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + ")(?![\\p{L}\\p{N}_./-])"
                return try? NSRegularExpression(pattern: pattern)
            }
        }
        var parts: [String: [WorkshopMessagePart]] = [:]
        var assistantOwners: [String: String] = [:]
        var fileOwners: [String: String] = [:]
        var parsedIDs = Set<String>(), matchedIDs = Set<String>()
        for entry in presentation.history {
            if entry.role == "assistant", entry.kind != "imageGeneration" {
                parsedIDs.insert(entry.id)
                if parsed[entry.id]?.text != entry.text {
                    parsed[entry.id] = Parsed(text: entry.text, parts: parseMessage(entry.text))
                }
                parts[entry.id] = parsed[entry.id]?.parts
            }
            guard !patterns.isEmpty, entry.role == "assistant" || entry.kind == "fileChange" else { continue }
            matchedIDs.insert(entry.id)
            if matched[entry.id]?.text != entry.text {
                let text = Self.normalize(entry.text)
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                let ids = Set(patterns.compactMap { id, regex in regex.firstMatch(in: text, range: range) == nil ? nil : id })
                matched[entry.id] = Matched(text: entry.text, artifacts: ids)
            }
            for id in matched[entry.id]?.artifacts ?? [] {
                if entry.role == "assistant" {
                    if assistantOwners[id] == nil { assistantOwners[id] = entry.id }
                } else if fileOwners[id] == nil { fileOwners[id] = entry.id }
            }
        }
        parsed = parsed.filter { parsedIDs.contains($0.key) }
        matched = matched.filter { matchedIDs.contains($0.key) }
        var placement: [String: [WorkshopArtifact]] = [:]
        for artifact in artifacts {
            if let owner = assistantOwners[artifact.id] ?? fileOwners[artifact.id] {
                placement[owner, default: []].append(artifact)
            }
        }
        return WorkshopTranscriptLayout(revision: revision,
            groups: WorkshopEntryGroup.group(presentation.history, artifactsAfter: Set(placement.keys)),
            queued: presentation.queued, artifactsByEntry: placement, messageParts: parts, questionReplies: questionReplies,
            turnFooters: WorkshopTurn.footers(in: entries))
    }

    private static func normalize(_ text: String) -> String {
        (text.removingPercentEncoding ?? text).replacingOccurrences(of: "\\\\", with: "\\")
            .replacingOccurrences(of: "\\", with: "/").lowercased()
    }
}
