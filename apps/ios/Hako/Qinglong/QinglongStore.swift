import Foundation
import Combine

struct QinglongConfiguration: Codable {
    var connections: [QinglongConnection] = []
    var selectedID: String?
}

enum QinglongCredentials {
    private static let storage = SecureStorage.namespace("me.stackli.hako.qinglong")
    static func load(storage: any SecretStorage = Self.storage) throws -> QinglongConfiguration {
        guard let data = try storage.read(account: "configuration") else { return QinglongConfiguration() }
        return try JSONDecoder().decode(QinglongConfiguration.self, from: data)
    }
    static func save(_ configuration: QinglongConfiguration, storage: any SecretStorage = Self.storage) throws {
        try storage.save(JSONEncoder().encode(configuration), account: "configuration", accessibility: .whenUnlocked)
    }
}

@MainActor final class QinglongStore: ObservableObject {
    static let shared = QinglongStore()
    @Published private(set) var configuration = QinglongConfiguration()
    @Published private(set) var items: [QinglongResource: [QinglongItem]] = [:]
    @Published private(set) var errors: [QinglongResource: String] = [:]
    @Published private(set) var loading = Set<QinglongResource>()
    @Published private(set) var updated: [QinglongResource: Date] = [:]
    @Published private(set) var busy = false
    @Published private(set) var outcomes: [String: QinglongOutcome] = [:]
    @Published private(set) var outcomesComplete = false
    private var outcomeSignatures: [String: String] = [:]
    @Published var message: String?
    @Published var configurationError: String?
    @Published private(set) var revision = UUID()
    private var api: QinglongClient?
    private let refreshes = QinglongRefreshCoordinator()
    private var loaded = false
    var connection: QinglongConnection? { configuration.connections.first { $0.id == configuration.selectedID } }

    func load() {
        guard !loaded else { return }
        do {
            let saved = try QinglongCredentials.load()
            configuration = saved
            if connection == nil { configuration.selectedID = saved.connections.first?.id }
            api = try connection.map { try QinglongClient(connection: $0) }
            loaded = true; configurationError = nil
        } catch { configurationError = "无法读取青龙连接，请解锁设备后重试。原配置未改动。" }
    }

    private func apply(_ configuration: QinglongConfiguration) throws {
        guard !busy else { throw QinglongFailure(message: "请等待当前操作结束后切换连接。") }
        guard configurationError == nil else { throw QinglongFailure(message: "请先重新读取原有连接，避免覆盖尚未成功读取的配置。") }
        let connection = configuration.connections.first { $0.id == configuration.selectedID }
        let next = try connection.map { try QinglongClient(connection: $0) }
        try QinglongCredentials.save(configuration)
        self.configuration = configuration; api = next; loaded = true; configurationError = nil
        refreshes.invalidate()
        revision = UUID(); items = [:]; errors = [:]; loading = []; updated = [:]; message = nil
        outcomes = [:]; outcomeSignatures = [:]; outcomesComplete = false
    }

    func save(_ draft: QinglongConnection) throws {
        var next = configuration
        let value = try draft.normalized()
        if let index = next.connections.firstIndex(where: { $0.id == value.id }) { next.connections[index] = value }
        else { next.connections.append(value) }
        next.selectedID = value.id
        try apply(next)
    }
    func select(_ id: String) throws {
        guard id != configuration.selectedID else { return }
        var next = configuration; next.selectedID = id; try apply(next)
    }
    func remove(_ id: String) throws {
        var next = configuration; next.connections.removeAll { $0.id == id }
        if next.selectedID == id { next.selectedID = next.connections.first?.id }
        try apply(next)
    }
    func client() throws -> QinglongClient {
        guard let api else { throw QinglongFailure(message: "请先配置青龙连接。") }
        return api
    }
    func refresh(_ resource: QinglongResource) async {
        let ticket = revision
        await refreshes.run(resource) {
            guard ticket == self.revision else { return }
            await self.read(resource)
        }
    }
    private func read(_ resource: QinglongResource) async {
        guard !Task.isCancelled, let api else { return }
        let ticket = revision
        loading.insert(resource)
        defer { if ticket == revision { loading.remove(resource) } }
        do {
            let values = try await api.list(resource)
            try Task.checkCancellation()
            guard ticket == revision else { return }
            items[resource] = values; errors[resource] = nil; updated[resource] = .now
            if resource == .tasks {
                outcomesComplete = false
                let ids = Set(values.map(\.id)); outcomes = outcomes.filter { ids.contains($0.key) }
                for item in values {
                    guard !Task.isCancelled, ticket == revision else { return }
                    let signature = item.raw["status"].text + ":" + item.raw["last_running_time"].text
                    guard outcomeSignatures[item.id] != signature else { continue }
                    do {
                        let result = try await api.latestOutcome(item)
                        guard ticket == revision else { return }
                        outcomes[item.id] = result; outcomeSignatures[item.id] = signature
                    } catch let failure as QinglongFailure where failure.status == 404 || failure.status == 410 || failure.status == 403 { break }
                    catch { break }
                }
                if ticket == revision { outcomesComplete = values.allSatisfy { outcomeSignatures[$0.id] == $0.raw["status"].text + ":" + $0.raw["last_running_time"].text } }
            }
        } catch {
            guard ticket == revision, !Task.isCancelled else { return }
            errors[resource] = error.localizedDescription
        }
    }

    @discardableResult func perform(_ resource: QinglongResource, success: String,
                                    operation: (QinglongClient) async throws -> Void) async -> Bool {
        guard !busy else { return false }
        busy = true
        let ticket = revision
        defer { busy = false }
        do {
            try await operation(client())
            guard ticket == revision else { return false }
            message = success
            await refresh(resource)
            return true
        } catch {
            guard ticket == revision else { return false }
            message = error.localizedDescription
            return false
        }
    }
    func action(_ action: String, item: QinglongItem) async {
        await perform(item.resource, success: "请求已提交，请刷新状态或查看执行日志。") { try await $0.action(action, item: item) }
    }
    func delete(_ item: QinglongItem) async -> Bool {
        await perform(item.resource, success: "已删除。") { try await $0.delete(item) }
    }
    func saveEnvironment(_ item: QinglongItem?, fields: [String: String], enabled: Bool) async -> QinglongEnvironmentSaveResult? {
        var result: QinglongEnvironmentSaveResult?
        let success = await perform(.envs, success: "已保存。") { result = try await $0.saveEnvironment(item, fields: fields, enabled: enabled) }
        if let error = result?.stateError { message = error }
        return success ? result : nil
    }
    func saveRecord(_ resource: QinglongResource, item: QinglongItem?, fields: [String: String]) async -> Bool {
        var body = item?.editPayload(fields) ?? .fields(fields)
        if resource == .envs && item == nil { body = .array([body]) }
        let payload = body
        return await perform(resource, success: "已保存。") {
            _ = try await $0.call([resource.rawValue], method: item == nil ? "POST" : "PUT", body: payload)
        }
    }
}
