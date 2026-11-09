import Foundation

// Host capability contract. No credentials, transport DTOs or child feature types.
protocol GitHubRepositoryAccess {
    var storageScope: String { get }
    func listFiles(in directory: String) async throws -> GitHubDirectorySnapshot
    func readFile(at path: String, revision: String?) async throws -> GitHubFileSnapshot
    func commit(files: [String: String], expectedHead: String, message: GitHubCommitMessage) async throws -> GitHubCommitResult
}

struct GitHubDirectorySnapshot {
    struct Entry { let name: String; let kind: String }
    let head: String
    let entries: [Entry]
}

struct GitHubFileSnapshot {
    let head: String
    let text: String?
    // Includes the last deletion commit even when the file no longer exists.
    let lastCommitAt: Date?
}

struct GitHubCommitMessage {
    let headline: String
    var body: String? = nil
}

enum GitHubCommitResult: Equatable {
    case committed(String)
    case unchanged
    case staleHead
}
