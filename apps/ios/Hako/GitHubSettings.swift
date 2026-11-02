import Foundation

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
