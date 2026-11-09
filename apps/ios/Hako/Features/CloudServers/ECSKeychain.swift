import Foundation

// The child owns its schema and validation; the host owns secure persistence.
enum ECSKeychain {
    private static let storage: any SecretStorage = SecureStorage.namespace("me.stackli.hako.ecs")

    static func load(storage: any SecretStorage = Self.storage) throws -> ECSConnection? {
        let data: Data?
        do { data = try storage.read(account: "connection") }
        catch let error as SecretStorageError {
            throw ECSFailure(message: "无法读取 ECS 凭据（\(error.status)），请解锁手机后重试。")
        }
        return try data.map { try JSONDecoder().decode(ECSConnection.self, from: $0) }
    }

    static func save(_ value: ECSConnection, storage: any SecretStorage = Self.storage) throws {
        let data = try JSONEncoder().encode(value.validated())
        do { try storage.save(data, account: "connection", accessibility: .whenUnlocked) }
        catch let error as SecretStorageError {
            throw ECSFailure(message: "无法保存 ECS 连接（\(error.status)），原配置已保留。")
        }
    }
}
