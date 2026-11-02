import Foundation

struct SportsGitHub {
    let repository: any GitHubRepositoryAccess

    func sportsPull(localYears: Set<String>) async throws -> SportsRemote {
        let index = try await repository.listFiles(in: "data/sports")
        let years = Set(index.entries.compactMap { entry -> String? in
            guard entry.kind == "blob", entry.name.range(of: #"^[0-9]{4}\.csv$"#, options: .regularExpression) != nil else { return nil }
            return String(entry.name.prefix(4))
        })
        var remote = SportsRemote(records: [], modifiedAt: [:], existingYears: years, head: index.head)
        for year in years.union(localYears).sorted() {
            guard year.range(of: #"^[0-9]{4}$"#, options: .regularExpression) != nil else { throw SportsError(message: "运动年度无效。") }
            try Task.checkCancellation()
            let file = try await repository.readFile(at: "data/sports/\(year).csv", revision: index.head)
            if let date = file.lastCommitAt { remote.modifiedAt[year] = date }
            else if file.text != nil { throw SportsError(message: "无法确认运动 CSV 的最后提交时间，已停止同步。") }
            if let text = file.text { remote.records += try SportsCSV.decode(text, year: year) }
        }
        return remote
    }

    func sportsCommit(files: [String: String], head: String) async throws -> Bool {
        let result = try await repository.commit(files: files, expectedHead: head,
                                                message: GitHubCommitMessage(headline: "Update sports records"))
        return result != .staleHead
    }
}
