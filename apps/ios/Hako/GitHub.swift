import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct GitHubClient {
    let settings: GitHubSettings
    let token: String
    var session: URLSession = .shared

    struct APIError: Decodable { let message: String; let type: String? }
    struct Envelope<T: Decodable>: Decodable { let data: T?; let errors: [APIError]? }
    struct SnapshotData: Decodable {
        struct Repository: Decodable {
            struct Ref: Decodable {
                struct Commit: Decodable {
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
                    let oid: String
                    let file: File?
                }
                let target: Commit?
            }
            let ref: Ref?
        }
        let repository: Repository?
    }
    struct MutationData: Decodable {
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

    static let snapshotQuery = """
    query HakoSnapshot($owner: String!, $name: String!, $ref: String!, $path: String!) {
      repository(owner: $owner, name: $name) {
        ref(qualifiedName: $ref) {
          target { ... on Commit {
            oid
            file(path: $path) { object { ... on Blob { text isBinary isTruncated } } }
          } }
        }
      }
    }
    """
    static let commitMutation = """
    mutation HakoCommit($input: CreateCommitOnBranchInput!) {
      createCommitOnBranch(input: $input) {
        commit { oid signature { isValid wasSignedByGitHub } }
      }
    }
    """
    static let yearsQuery = """
    query HakoYears($owner: String!, $name: String!, $ref: String!, $path: String!) {
      repository(owner: $owner, name: $name) {
        ref(qualifiedName: $ref) {
          target { ... on Commit {
            oid
            file(path: $path) { object { ... on Tree { entries { name type } } } }
          } }
        }
      }
    }
    """

    func graphql<T: Decodable>(_ query: String, variables: [String: Any], as: T.Type) async throws -> Envelope<T> {
        var request = URLRequest(url: URL(string: "https://api.github.com/graphql")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw HakoError(message: "GitHub 同步失败（HTTP \(status)）。请检查网络及 Token 的 Contents 读写权限；本地记录已保留。")
        }
        return try JSONDecoder().decode(Envelope<T>.self, from: data)
    }

    func failure(_ errors: [APIError]) -> HakoError {
        HakoError(message: "GitHub 同步失败：" + errors.map(\.message).joined(separator: "；") + "。本地记录已保留。")
    }

    func validate(directory: String) throws {
        try settings.validate()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !directory.isEmpty, directory.unicodeScalars.allSatisfy(allowed.contains) else {
            throw HakoError(message: "模块目录名称无效，请使用文字、数字、连字符或下划线。")
        }
        guard !token.isEmpty else { throw HakoError(message: "请先在设置中保存 GitHub Token。") }
    }

    func years(directory: String) async throws -> [String] {
        try validate(directory: directory)
        let repository = try settings.repository()
        let snapshot = try await graphql(Self.yearsQuery, variables: [
            "owner": repository.owner, "name": repository.name,
            "ref": "refs/heads/" + settings.branch, "path": "data/\(directory)"
        ], as: SnapshotData.self)
        if let errors = snapshot.errors, !errors.isEmpty { throw failure(errors) }
        guard let head = snapshot.data?.repository?.ref?.target else {
            throw HakoError(message: "找不到仓库或分支 \(settings.branch)。请确认仓库已初始化、分支存在且 Token 有权访问。")
        }
        guard let file = head.file else { return [] }
        guard let entries = file.object?.entries else {
            throw HakoError(message: "远端模块路径不是有效目录，已停止同步。")
        }
        return entries.compactMap { entry in
            guard entry.type == "blob", entry.name.range(of: #"^[0-9]{4}\.csv$"#, options: .regularExpression) != nil else { return nil }
            return String(entry.name.prefix(4))
        }.sorted()
    }

}
