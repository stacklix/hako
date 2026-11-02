import Foundation

// This test compiles with the host contract alone: no GitHubSettings, TokenStore,
// concrete service, URLSession, Security, or screen-time models are linked.
private final class FakeRepository: GitHubRepositoryAccess {
    let storageScope = "opaque-test-scope"
    var files: [String: GitHubFileSnapshot] = [:]
    var reads: [String] = []
    var submitted: [String: String] = [:]
    var result = GitHubCommitResult.committed("new-head")
    func listFiles(in directory: String) async throws -> GitHubDirectorySnapshot {
        precondition(directory == "data/sports")
        return GitHubDirectorySnapshot(head: "snapshot", entries: [.init(name: "2026.csv", kind: "blob"), .init(name: "README.md", kind: "blob")])
    }
    func readFile(at path: String, revision: String?) async throws -> GitHubFileSnapshot {
        precondition(revision == "snapshot")
        reads.append(path)
        return files[path] ?? GitHubFileSnapshot(head: "snapshot", text: nil, lastCommitAt: nil)
    }
    func commit(files: [String: String], expectedHead: String, message: GitHubCommitMessage) async throws -> GitHubCommitResult {
        precondition(expectedHead == "snapshot" && message.headline == "Update sports records")
        submitted = files
        return result
    }
}

@main struct SportsRepositoryTests {
    static func main() async throws {
        let host = FakeRepository()
        let record = SportsRecord(id: UUID(), date: "20260701", type: "Swimming", distance: 1.05, duration: 69)
        let stamp = Date(timeIntervalSince1970: 100)
        host.files["data/sports/2026.csv"] = GitHubFileSnapshot(head: "snapshot", text: SportsCSV.encode([record]), lastCommitAt: stamp)
        let child = SportsGitHub(repository: host)
        let pulled = try await child.sportsPull(localYears: ["2025"])
        precondition(host.reads == ["data/sports/2025.csv", "data/sports/2026.csv"])
        precondition(pulled.records == [record] && pulled.modifiedAt["2026"] == stamp)
        let successful = try await child.sportsCommit(files: ["data/sports/2026.csv": SportsCSV.encode([record])], head: pulled.head)
        precondition(successful && host.submitted.count == 1)
        host.result = .staleHead
        let stale = try await child.sportsCommit(files: host.submitted, head: pulled.head)
        precondition(!stale)
        host.files["data/sports/2026.csv"] = GitHubFileSnapshot(head: "snapshot", text: SportsCSV.encode([record]), lastCommitAt: nil)
        do { _ = try await child.sportsPull(localYears: []); fatalError("Accepted missing file timestamp") }
        catch is SportsError { }
        print("Host contract tests passed: child compiles and syncs without credentials or a concrete GitHub client")
    }
}
