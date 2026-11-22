import Foundation

struct TaskProgressSnapshot: Decodable {
    let tasks: [TaskProgressItem]
    let warning: String?
}

struct TaskProgressItem: Decodable, Identifiable, Equatable {
    struct Stage: Decodable, Identifiable, Equatable {
        let id: String
        let name: String
        let status: String
    }
    struct Release: Codable, Equatable {
        let bundleId: String
        let version: String
        let build: String
        let metadataUrl: String
    }
    let id: String
    let name: String
    let project: String
    let platform: String
    let status: String
    let createdAt: Int64
    let updatedAt: Int64
    let stages: [Stage]
    let message: String?
    let release: Release?
    let summary: String?

    var active: Bool { ["running", "queued", "pending"].contains(status) }
    var completedStages: Int { stages.filter { ["succeeded", "skipped"].contains($0.status) }.count }
    var currentStage: Stage? { stages.first { $0.status == "running" } ?? stages.first { $0.status == "failed" } }
    func stale(at date: Date) -> Bool { active && date.timeIntervalSince1970 * 1000 - Double(updatedAt) > 60_000 }

    static func title(_ status: String) -> String {
        switch status {
        case "running": "执行中"
        case "pending", "queued": "等待执行"
        case "succeeded": "已完成"
        case "failed": "失败"
        case "cancelled": "已取消"
        case "skipped": "已跳过"
        default: "状态待确认"
        }
    }
}

/// Task references anchor cards to the originating turn, independent of later
/// messages and progress updates. Only the latest referenced build turn appears.
struct TaskProgressPlacement {
    struct Message {
        let id: String
        let text: String
        let isUser: Bool
    }
    private(set) var after: [String: [TaskProgressItem]] = [:]

    init(tasks: [TaskProgressItem], messages: [Message]) {
        var turnEnds = Array(repeating: max(0, messages.count - 1), count: messages.count)
        var end = max(0, messages.count - 1)
        for index in messages.indices.reversed() {
            if index + 1 < messages.count, messages[index + 1].isUser { end = index }
            turnEnds[index] = end
        }
        var latestTurn: Int?
        var latestTasks: [TaskProgressItem] = []
        for task in tasks {
            let providerID = task.id.hasPrefix("xkode-") ? String(task.id.dropFirst(6)) : task.id
            let references = Set([task.id, providerID]).filter { !$0.isEmpty }
            let pattern = "(?<![A-Za-z0-9_-])(?:" + references.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + ")(?![A-Za-z0-9_-])"
            guard !references.isEmpty, let reference = messages.firstIndex(where: { $0.text.range(of: pattern, options: .regularExpression) != nil }) else {
                continue
            }
            let turn = turnEnds[reference]
            if latestTurn == nil || turn > latestTurn! {
                latestTurn = turn
                latestTasks = [task]
            } else if turn == latestTurn { latestTasks.append(task) }
        }
        if let latestTurn { after[messages[latestTurn].id] = latestTasks }
    }
}

struct TaskProgressVersion: Comparable, Equatable {
    private let values: [Int]
    init?(version: String, build: String) {
        func parts(_ text: String) -> [Int]? {
            let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
            guard (1...3).contains(pieces.count) else { return nil }
            var values = [Int]()
            for piece in pieces {
                guard !piece.isEmpty, piece.utf8.allSatisfy({ (48...57).contains($0) }), let value = Int(piece) else { return nil }
                values.append(value)
            }
            return values + Array(repeating: 0, count: 3 - values.count)
        }
        guard let version = parts(version), let build = parts(build) else { return nil }
        values = version + build
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.values.lexicographicallyPrecedes(rhs.values) }
}

struct TaskProgressReleaseMetadata: Decodable {
    let version: String
    let build: String
    let manifest: String

    var ordering: TaskProgressVersion? { TaskProgressVersion(version: version, build: build) }
    static func secureURL(_ text: String) -> URL? {
        guard text.count <= 1500, let url = URL(string: text), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.fragment == nil else { return nil }
        return url
    }
    func manifestURL(relativeTo metadata: URL) -> URL? {
        guard ordering != nil, Self.secureURL(metadata.absoluteString) != nil,
              manifest.range(of: #"\A[A-Za-z0-9_-]+\.plist\z"#, options: .regularExpression) != nil else { return nil }
        return metadata.deletingLastPathComponent().appendingPathComponent(manifest)
    }
    func validatesManifest(_ data: Data, bundleId: String) -> Bool {
        guard data.count <= 256 * 1024,
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let items = object["items"] as? [[String: Any]], items.count == 1, let item = items.first,
              let metadata = item["metadata"] as? [String: Any], metadata["bundle-identifier"] as? String == bundleId,
              metadata["bundle-version"] as? String == build, metadata["kind"] as? String == "software",
              let assets = item["assets"] as? [[String: Any]],
              let package = assets.first(where: { $0["kind"] as? String == "software-package" }),
              let url = package["url"] as? String else { return false }
        return Self.secureURL(url) != nil
    }
    static func installationURL(manifest: URL) -> URL? {
        guard secureURL(manifest.absoluteString) != nil else { return nil }
        var components = URLComponents()
        components.scheme = "itms-services"
        components.host = ""
        components.queryItems = [URLQueryItem(name: "action", value: "download-manifest"), URLQueryItem(name: "url", value: manifest.absoluteString)]
        return components.url
    }
}
