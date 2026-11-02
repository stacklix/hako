import Foundation

enum TokenStore {
    private static let storage = SecureStorage.namespace("me.stackli.hako.github")
    static func read() throws -> String {
        guard let data = try storage.read(account: "token") else { return "" }
        guard let token = String(data: data, encoding: .utf8) else { throw HakoError(message: "保存的 Token 格式无效。") }
        return token
    }
    static func save(_ token: String) throws {
        if token.isEmpty { try storage.delete(account: "token") }
        else { try storage.save(Data(token.utf8), account: "token", accessibility: .afterFirstUnlock) }
    }
}
