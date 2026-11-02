import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct GitHubService: GitHubRepositoryAccess {
    private let settings: GitHubSettings
    private let tokenProvider: () throws -> String
    private let session: URLSession

    init(settings: GitHubSettings, tokenProvider: @escaping () throws -> String, session: URLSession = HTTPTransport.shared) {
        self.settings = settings; self.tokenProvider = tokenProvider; self.session = session
    }

    var storageScope: String {
        settings.repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: #"\.git/?$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "|" + settings.branch
    }

    private struct APIError: Decodable { let message: String; let type: String? }
    private struct Envelope<T: Decodable>: Decodable { let data: T?; let errors: [APIError]? }
    private struct SnapshotData: Decodable {
        struct Repository: Decodable {
            struct Ref: Decodable { let target: Commit? }
            let ref: Ref?
            let object: Commit?
        }
        let repository: Repository?
    }
    private struct Commit: Decodable {
        struct File: Decodable {
            struct Object: Decodable {
                struct Entry: Decodable { let name: String; let type: String }
                let text: String?
                let isBinary: Bool?
                let isTruncated: Bool?
                let entries: [Entry]?
            }
            let object: Object?
        }
        struct History: Decodable {
            struct Node: Decodable { let committedDate: String }
            let nodes: [Node]
        }
        let oid: String
        let file: File?
        let history: History?
    }
    private struct MutationData: Decodable {
        struct Result: Decodable {
            struct Commit: Decodable {
                struct Signature: Decodable { let isValid: Bool; let wasSignedByGitHub: Bool }
                let oid: String
                let signature: Signature?
            }
            let commit: Commit?
        }
        let createCommitOnBranch: Result?
    }

    private static let directoryQuery = """
    query HakoDirectory($owner: String!, $name: String!, $ref: String!, $path: String!) {
      repository(owner: $owner, name: $name) {
        ref(qualifiedName: $ref) { target { ... on Commit {
          oid
          file(path: $path) { object { ... on Tree { entries { name type } } } }
        } } }
      }
    }
    """
    private static let snapshotQuery = """
    query HakoSnapshot($owner: String!, $name: String!, $ref: String!, $path: String!) {
      repository(owner: $owner, name: $name) {
        ref(qualifiedName: $ref) { target { ... on Commit {
          oid
          file(path: $path) { object { ... on Blob { text isBinary isTruncated } } }
          history(first: 1, path: $path) { nodes { committedDate } }
        } } }
      }
    }
    """
    private static let pinnedQuery = """
    query HakoFile($owner: String!, $name: String!, $oid: GitObjectID!, $path: String!) {
      repository(owner: $owner, name: $name) {
        object(oid: $oid) { ... on Commit {
          oid
          file(path: $path) { object { ... on Blob { text isBinary isTruncated } } }
          history(first: 1, path: $path) { nodes { committedDate } }
        } }
      }
    }
    """
    private static let commitMutation = """
    mutation HakoCommit($input: CreateCommitOnBranchInput!) {
      createCommitOnBranch(input: $input) {
        commit { oid signature { isValid wasSignedByGitHub } }
      }
    }
    """

    private func validate(path: String) throws {
        try settings.validate()
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.contains("\\"), parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw HakoError(message: "GitHub 文件路径无效。")
        }
    }
    private func variables(path: String) throws -> [String: Any] {
        try validate(path: path)
        let repository = try settings.repository()
        return ["owner": repository.owner, "name": repository.name, "ref": "refs/heads/" + settings.branch, "path": path]
    }
    private func failure(_ errors: [APIError]) -> HakoError {
        HakoError(message: "GitHub 请求失败：" + errors.map(\.message).joined(separator: "；"))
    }
    private func graphql<T: Decodable>(_ query: String, variables: [String: Any], as: T.Type) async throws -> Envelope<T> {
        let token = try tokenProvider()
        guard !token.isEmpty else { throw HakoError(message: "请先在主应用设置中保存 GitHub Token。") }
        var request = URLRequest(url: URL(string: "https://api.github.com/graphql")!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw HakoError(message: "GitHub 请求失败（HTTP \(status)），请检查网络及主应用的仓库访问权限。") }
        return try JSONDecoder().decode(Envelope<T>.self, from: data)
    }

    func listFiles(in directory: String) async throws -> GitHubDirectorySnapshot {
        let response = try await graphql(Self.directoryQuery, variables: variables(path: directory), as: SnapshotData.self)
        if let errors = response.errors, !errors.isEmpty { throw failure(errors) }
        guard let head = response.data?.repository?.ref?.target, !head.oid.isEmpty else {
            throw HakoError(message: "找不到 GitHub 仓库或分支，请检查主应用配置。")
        }
        if head.file != nil && head.file?.object?.entries == nil { throw HakoError(message: "GitHub 指定路径不是可读取的目录。") }
        let entries = (head.file?.object?.entries ?? []).map { GitHubDirectorySnapshot.Entry(name: $0.name, kind: $0.type) }
        return GitHubDirectorySnapshot(head: head.oid, entries: entries)
    }

    func readFile(at path: String, revision: String?) async throws -> GitHubFileSnapshot {
        var vars = try variables(path: path)
        let response: Envelope<SnapshotData>
        if let revision {
            guard !revision.isEmpty else { throw HakoError(message: "GitHub 快照标识无效。") }
            vars["ref"] = nil; vars["oid"] = revision
            response = try await graphql(Self.pinnedQuery, variables: vars, as: SnapshotData.self)
        } else { response = try await graphql(Self.snapshotQuery, variables: vars, as: SnapshotData.self) }
        if let errors = response.errors, !errors.isEmpty { throw failure(errors) }
        guard let commit = revision == nil ? response.data?.repository?.ref?.target : response.data?.repository?.object,
              !commit.oid.isEmpty else { throw HakoError(message: "无法读取 GitHub 仓库快照。") }
        if let revision, commit.oid != revision { throw HakoError(message: "GitHub 返回的快照与请求不一致。") }
        var text: String?
        if let file = commit.file {
            guard let object = file.object, object.isBinary == false, object.isTruncated == false, let value = object.text else {
                throw HakoError(message: "GitHub 文件不是完整的可读取文本，已停止处理。")
            }
            text = value
        }
        var modified: Date?
        if let timestamp = commit.history?.nodes.first?.committedDate {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = ISO8601DateFormatter().date(from: timestamp) ?? fractional.date(from: timestamp) else {
                throw HakoError(message: "GitHub 文件提交时间无效。")
            }
            modified = date
        }
        return GitHubFileSnapshot(head: commit.oid, text: text, lastCommitAt: modified)
    }

    func commit(files: [String: String], expectedHead: String, message: GitHubCommitMessage) async throws -> GitHubCommitResult {
        guard !files.isEmpty else { return .unchanged }
        try files.keys.forEach { try validate(path: $0) }
        guard !expectedHead.isEmpty else { throw HakoError(message: "GitHub 提交缺少快照标识。") }
        let repository = try settings.repository()
        var description = ["headline": message.headline]
        if let body = message.body { description["body"] = body }
        let additions = files.keys.sorted().map { ["path": $0, "contents": Data(files[$0]!.utf8).base64EncodedString()] }
        let input: [String: Any] = [
            "branch": ["repositoryNameWithOwner": "\(repository.owner)/\(repository.name)", "branchName": settings.branch],
            "expectedHeadOid": expectedHead, "message": description, "fileChanges": ["additions": additions]
        ]
        let response = try await graphql(Self.commitMutation, variables: ["input": input], as: MutationData.self)
        if let errors = response.errors, !errors.isEmpty {
            if errors.allSatisfy({ $0.type == "STALE_DATA" }) { return .staleHead }
            throw failure(errors)
        }
        guard let commit = response.data?.createCommitOnBranch?.commit, !commit.oid.isEmpty else {
            throw HakoError(message: "GitHub 未确认提交结果。")
        }
        guard commit.signature?.isValid == true, commit.signature?.wasSignedByGitHub == true else {
            throw HakoError(message: "数据已提交，但 GitHub 签名状态尚未确认，请检查提交 \(commit.oid)。")
        }
        return .committed(commit.oid)
    }
}
