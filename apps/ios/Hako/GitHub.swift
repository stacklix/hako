import Foundation
import Security

struct GitHubSettings: Codable, Equatable {
    var repositoryURL = ""
    var branch = "master"
    func repository() throws -> (owner: String, name: String) {
        let text = repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URLComponents(string: text), url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "github.com", url.user == nil, url.password == nil,
              url.port == nil, url.query == nil, url.fragment == nil else {
            throw HakoError(message: "请输入 GitHub 仓库地址，例如 https://github.com/stackli/personal-data。")
        }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 2 else {
            throw HakoError(message: "请填写仓库首页地址，不要包含分支、文件或目录路径。")
        }
        let owner = parts[0]
        let name = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard [owner, name].allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy(allowed.contains) }) else {
            throw HakoError(message: "仓库地址中的所有者或仓库名称无效。")
        }
        return (owner, name)
    }
    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: "github.settings"), let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    func save() throws { UserDefaults.standard.set(try JSONEncoder().encode(self), forKey: "github.settings") }
    func validate() throws {
        _ = try repository()
        guard !branch.isEmpty, !branch.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw HakoError(message: "请填写分支名称，且不要包含空格。")
        }
    }

}

enum TokenStore {
    static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "me.stackli.hako.github", kSecAttrAccount as String: "token"]
    static func read() throws -> String {
        var q = query; q[kSecReturnData as String] = true
        var value: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &value)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = value as? Data, let token = String(data: data, encoding: .utf8) else { throw HakoError(message: "无法读取 Keychain（\(status)）。请解锁设备后重试。") }
        return token
    }
    static func save(_ token: String) throws {
        if token.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw HakoError(message: "无法删除 Token（\(status)）。") }
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw HakoError(message: "无法保存 Token（\(status)）。") }
    }
}

struct GitHubClient {
    let settings: GitHubSettings
    let token: String
    var session: URLSession = .shared

    private struct APIError: Decodable { let message: String; let type: String? }
    private struct Envelope<T: Decodable>: Decodable { let data: T?; let errors: [APIError]? }
    private struct SnapshotData: Decodable {
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

    private static let snapshotQuery = """
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
    private static let commitMutation = """
    mutation HakoCommit($input: CreateCommitOnBranchInput!) {
      createCommitOnBranch(input: $input) {
        commit { oid signature { isValid wasSignedByGitHub } }
      }
    }
    """
    private static let yearsQuery = """
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

    private func graphql<T: Decodable>(_ query: String, variables: [String: Any], as: T.Type) async throws -> Envelope<T> {
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

    private func failure(_ errors: [APIError]) -> HakoError {
        HakoError(message: "GitHub 同步失败：" + errors.map(\.message).joined(separator: "；") + "。本地记录已保留。")
    }

    private func validate(directory: String) throws {
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

    // Return the exact merged rows from the successful snapshot/commit, including on a no-op.
    @discardableResult
    func push(directory: String, year: String, rows: [[String]]) async throws -> [[String]] {
        try validate(directory: directory)
        guard year.range(of: #"^[0-9]{4}$"#, options: .regularExpression) != nil else {
            throw HakoError(message: "年度文件名称无效。")
        }
        _ = try rows.map { try DailyUsage.fromCSV($0, year: year) }
        let repository = try settings.repository()
        let path = "data/\(directory)/\(year).csv"
        for attempt in 0..<3 {
            try Task.checkCancellation()
            // Read the file and its parent commit in one snapshot to avoid races.
            let snapshot = try await graphql(Self.snapshotQuery, variables: [
                "owner": repository.owner, "name": repository.name,
                "ref": "refs/heads/" + settings.branch, "path": path
            ], as: SnapshotData.self)
            if let errors = snapshot.errors, !errors.isEmpty { throw failure(errors) }
            guard let head = snapshot.data?.repository?.ref?.target else {
                throw HakoError(message: "找不到仓库或分支 \(settings.branch)。请确认仓库已初始化、分支存在且 Token 有权访问。")
            }
            var remote: String?
            if let file = head.file {
                guard let object = file.object, object.isBinary == false, object.isTruncated == false,
                      let text = object.text else {
                    throw HakoError(message: "远端文件不是完整的文本 CSV，已停止同步。")
                }
                remote = text
            }
            let csv = try CSV.merge(remote: remote, local: rows, year: year)
            let mergedRows = Array(try CSV.parse(csv).dropFirst())
            // Validate values before uploading or importing them into the database.
            _ = try mergedRows.map { try DailyUsage.fromCSV($0, year: year) }
            let existingDates = Set(try remote.map { try CSV.parse($0).dropFirst().map { $0[0] } } ?? [])
            let newDates = Set(rows.map { $0[0] }).subtracting(existingDates).sorted()
            guard let first = newDates.first, let last = newDates.last else { return mergedRows }
            let dateLabel = first == last ? first : "\(first) ~ \(last)"
            let input: [String: Any] = [
                "branch": ["repositoryNameWithOwner": "\(repository.owner)/\(repository.name)", "branchName": settings.branch],
                "expectedHeadOid": head.oid,
                "message": ["headline": "Update \(directory): \(dateLabel)",
                            "body": "Add missing dates: " + newDates.joined(separator: ", ")],
                "fileChanges": ["additions": [["path": path, "contents": Data(csv.utf8).base64EncodedString()]]]
            ]
            let result = try await graphql(Self.commitMutation, variables: ["input": input], as: MutationData.self)
            if let errors = result.errors, !errors.isEmpty {
                // A concurrent writer moved the branch: reread and merge again.
                if errors.allSatisfy({ $0.type == "STALE_DATA" }), attempt < 2 { continue }
                throw failure(errors)
            }
            guard let commit = result.data?.createCommitOnBranch?.commit, !commit.oid.isEmpty else {
                throw HakoError(message: "GitHub 未返回提交结果，请稍后重试。")
            }
            guard commit.signature?.isValid == true, commit.signature?.wasSignedByGitHub == true else {
                throw HakoError(message: "数据已提交，但 GitHub 尚未确认签名有效。请在仓库检查提交 \(commit.oid) 的 Verified 状态。")
            }
            return mergedRows
        }
        throw HakoError(message: "GitHub 分支持续变化，请稍后重试合并。")
    }
}
