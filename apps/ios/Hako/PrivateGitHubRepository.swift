import Foundation

// Never fall back to the public repository, even when private configuration is absent.
struct PrivateGitHubRepository: GitHubRepositoryAccess {
    let settings: GitHubSettings
    private var service: GitHubService { GitHubService(settings: settings, tokenProvider: { try TokenStore.read() }) }
    var storageScope: String { "private|" + service.storageScope }
    private func verify() async throws {
        try settings.validate()
        let repo = try settings.repository()
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo.owner)/\(repo.name)")!)
        let token = try TokenStore.read()
        guard !token.isEmpty else { throw HakoError(message: "请先配置 GitHub Token。") }
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await HTTPTransport.shared.data(for: request)
        struct Visibility: Decodable { let `private`: Bool }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let visibility = try? JSONDecoder().decode(Visibility.self, from: data), visibility.private else {
            throw HakoError(message: "无法确认资产仓库为私有库，已停止同步。请检查仓库地址及 Token 权限。")
        }
    }
    func listFiles(in directory: String) async throws -> GitHubDirectorySnapshot {
        try await verify(); return try await service.listFiles(in: directory)
    }
    func readFile(at path: String, revision: String?) async throws -> GitHubFileSnapshot {
        try await verify(); return try await service.readFile(at: path, revision: revision)
    }
    func commit(files: [String: String], expectedHead: String, message: GitHubCommitMessage) async throws -> GitHubCommitResult {
        try await verify(); return try await service.commit(files: files, expectedHead: expectedHead, message: message)
    }
}
