import Foundation

extension GitHubClient {
    private struct SportsFileData: Decodable {
        struct Repository: Decodable {
            struct Commit: Decodable {
                struct History: Decodable {
                    struct Node: Decodable { let committedDate: String }
                    let nodes: [Node]
                }
                let file: SnapshotData.Repository.Ref.Commit.File?
                let history: History
            }
            let object: Commit?
        }
        let repository: Repository?
    }

    // Pin every file and its path-specific history to one branch snapshot.
    func sportsPull(localYears: Set<String>) async throws -> SportsRemote {
        try validate(directory: "sports")
        let repository = try settings.repository()
        let index = try await graphql(Self.yearsQuery, variables: [
            "owner": repository.owner, "name": repository.name,
            "ref": "refs/heads/" + settings.branch, "path": "data/sports"
        ], as: SnapshotData.self)
        if let errors = index.errors, !errors.isEmpty { throw failure(errors) }
        guard let head = index.data?.repository?.ref?.target else {
            throw HakoError(message: "找不到 GitHub 仓库或分支，请检查主应用的 GitHub 配置。")
        }
        if head.file != nil && head.file?.object?.entries == nil {
            throw HakoError(message: "GitHub data/sports 不是目录，已停止同步。")
        }
        let years = Set((head.file?.object?.entries ?? []).compactMap { entry -> String? in
            guard entry.type == "blob", entry.name.range(of: #"^[0-9]{4}\.csv$"#, options: .regularExpression) != nil else { return nil }
            return String(entry.name.prefix(4))
        })
        let query = """
        query HakoSportsFile($owner: String!, $name: String!, $oid: GitObjectID!, $path: String!) {
          repository(owner: $owner, name: $name) {
            object(oid: $oid) { ... on Commit {
              file(path: $path) { object { ... on Blob { text isBinary isTruncated } } }
              history(first: 1, path: $path) { nodes { committedDate } }
            } }
          }
        }
        """
        var remote = SportsRemote(records: [], modifiedAt: [:], existingYears: years, head: head.oid)
        for year in years.union(localYears).sorted() {
            guard year.range(of: #"^[0-9]{4}$"#, options: .regularExpression) != nil else {
                throw SportsError(message: "运动年度无效。")
            }
            try Task.checkCancellation()
            let response = try await graphql(query, variables: [
                "owner": repository.owner, "name": repository.name, "oid": head.oid,
                "path": "data/sports/\(year).csv"
            ], as: SportsFileData.self)
            if let errors = response.errors, !errors.isEmpty { throw failure(errors) }
            guard let commit = response.data?.repository?.object else {
                throw HakoError(message: "无法读取运动数据的 GitHub 快照。")
            }
            if let timestamp = commit.history.nodes.first?.committedDate {
                guard let date = ISO8601DateFormatter().date(from: timestamp) else {
                    throw HakoError(message: "GitHub 提交时间无效，已停止同步。")
                }
                remote.modifiedAt[year] = date
            } else if commit.file != nil {
                throw HakoError(message: "无法确认运动 CSV 的最后提交时间，已停止同步。")
            }
            if let file = commit.file {
                guard let object = file.object, object.isBinary == false, object.isTruncated == false,
                      let text = object.text else { throw HakoError(message: "运动 CSV 不是完整文本，已停止同步。") }
                remote.records += try SportsCSV.decode(text, year: year)
            }
        }
        return remote
    }

    // One signed commit covers all affected years, including moves across year boundaries.
    // false means a known stale-head rejection; uncertain network writes are never retried here.
    func sportsCommit(files: [String: String], head: String) async throws -> Bool {
        try validate(directory: "sports")
        guard !files.isEmpty else { return true }
        let repository = try settings.repository()
        let additions = files.keys.sorted().map { ["path": $0, "contents": Data(files[$0]!.utf8).base64EncodedString()] }
        let input: [String: Any] = [
            "branch": ["repositoryNameWithOwner": "\(repository.owner)/\(repository.name)", "branchName": settings.branch],
            "expectedHeadOid": head, "message": ["headline": "Update sports records"],
            "fileChanges": ["additions": additions]
        ]
        let response = try await graphql(Self.commitMutation, variables: ["input": input], as: MutationData.self)
        if let errors = response.errors, !errors.isEmpty {
            if errors.allSatisfy({ $0.type == "STALE_DATA" }) { return false }
            throw failure(errors)
        }
        guard let commit = response.data?.createCommitOnBranch?.commit, !commit.oid.isEmpty else {
            throw HakoError(message: "GitHub 未确认运动数据提交结果，本地变更已保留。")
        }
        guard commit.signature?.isValid == true, commit.signature?.wasSignedByGitHub == true else {
            throw HakoError(message: "运动数据已提交，但签名状态尚未确认，请在 GitHub 检查 \(commit.oid)。")
        }
        return true
    }
}
