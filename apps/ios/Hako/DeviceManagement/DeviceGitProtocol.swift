import Foundation
import CryptoKit

enum DeviceGitCommand {
    static let list = "query.git.repositories"
    static let detail = "query.git.repository"
    static let operation = "query.git.operation"
    static let commit = "action.git.commit"
    static let push = "action.git.push"
    static let pull = "action.git.pull"
    static let remote = "query.git.remote"
    static let supporting: Set<String> = [detail, operation, commit, push, pull, remote]
}

struct DeviceGitRepository: Codable, Identifiable {
    let id: String
    let name: String
    let branch: String?
    let remoteName: String?
    let remoteUrl: String?
    let pushTarget: String?
    let changedCount: Int
    let ahead: Int?
    let behind: Int?
    let canCommit: Bool
    let canPush: Bool
    let error: String?
}

struct DeviceGitPage: Decodable {
    let root: String
    let repositories: [DeviceGitRepository]
    let nextCursor: String?
    let scanIncomplete: Bool
}

struct DeviceGitInventory: Codable {
    let root: String
    var repositories: [DeviceGitRepository]
    let scanIncomplete: Bool

    static func cacheFile(server: String, account: String, agent: String) -> URL {
        let identity = (try? JSONEncoder().encode([server, account, agent])) ?? Data()
        let digest = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        return URL.applicationSupportDirectory
            .appending(path: "Hako/DeviceGit", directoryHint: .isDirectory)
            .appending(path: digest + ".json", directoryHint: .notDirectory)
    }
}

struct DeviceGitDetail: Decodable {
    struct Change: Decodable, Identifiable {
        let path: String
        let status: String
        let index: Int
        var id: Int { index }
        var label: String {
            if status == "??" || status.contains("A") { return "新增" }
            if status.contains("U") { return "冲突" }
            if status.contains("D") { return "删除" }
            return "修改"
        }
    }
    struct Commit: Decodable, Identifiable {
        let id: String
        let subject: String
    }
    let repository: DeviceGitRepository
    let revision: String
    let changes: [Change]
    let pending: [Commit]
    let changesTruncated: Bool
    let pullSource: String?
    let pullUrl: String?
    let canPull: Bool?
    let remoteCheckFresh: Bool?
}

struct DeviceGitOperation: Decodable {
    enum State: String, Decodable { case running, succeeded, failed, unknown }
    let id: String
    let state: State
    let message: String?
}
