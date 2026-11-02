import Foundation

// The child owns its schema and validation; the host owns secure persistence.
enum ArcaneKeychain {
    private static let storage: any SecretStorage = SecureStorage.namespace("me.stackli.hako.arcane")

    static func load(storage: any SecretStorage = Self.storage) throws -> ArcaneConnection? {
        let data: Data?
        do { data = try storage.read(account: "connection") }
        catch let error as SecretStorageError {
            throw ArcaneFailure(message: "无法读取 Arcane 凭据（\(error.status)），请解锁手机后重试。")
        }
        return try data.map { try JSONDecoder().decode(ArcaneConnection.self, from: $0) }
    }

    static func save(_ value: ArcaneConnection, storage: any SecretStorage = Self.storage) throws {
        let data = try JSONEncoder().encode(value.normalized())
        do { try storage.save(data, account: "connection", accessibility: .whenUnlocked) }
        catch let error as SecretStorageError {
            throw ArcaneFailure(message: "无法保存 Arcane 连接（\(error.status)），原配置已保留。")
        }
    }
}
