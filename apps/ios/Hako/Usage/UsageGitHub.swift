import Foundation

extension GitHubClient {
    struct PushResult {
        let rows: [[String]]
        let inserted: Int
    }

    // Count only dates added by the successful commit, after any concurrency retries.
    @discardableResult
    func push(directory: String, year: String, rows: [[String]]) async throws -> PushResult {
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
            guard let first = newDates.first, let last = newDates.last else {
                return PushResult(rows: mergedRows, inserted: 0)
            }
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
            return PushResult(rows: mergedRows, inserted: newDates.count)
        }
        throw HakoError(message: "GitHub 分支持续变化，请稍后重试合并。")
    }

}
