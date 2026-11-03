import Foundation
import Combine

enum HeadplaneCredentials {
    private static let storage = SecureStorage.namespace("me.stackli.hako.headplane")
    static func load(storage: any SecretStorage = Self.storage) throws -> HeadplaneConnection? {
        guard let data = try storage.read(account: "connection") else { return nil }
        return try JSONDecoder().decode(HeadplaneConnection.self, from: data).normalized()
    }
    static func save(_ connection: HeadplaneConnection, storage: any SecretStorage = Self.storage) throws {
        try storage.save(JSONEncoder().encode(connection.normalized()), account: "connection", accessibility: .whenUnlocked)
    }
    static func remove(storage: any SecretStorage = Self.storage) throws { try storage.delete(account: "connection") }
}

@MainActor final class HeadplaneStore: ObservableObject {
    @Published private(set) var connection: HeadplaneConnection?
    @Published private(set) var revision = UUID()
    @Published private(set) var machines: HeadplaneMachines?
    @Published private(set) var policy: HeadplanePolicy?
    @Published private(set) var agent: HeadplaneAgentStatus?
    @Published private(set) var keys: [HeadplaneKey] = []
    @Published private(set) var values: [HeadplaneResource: HeadplaneJSON] = [:]
    @Published private(set) var errors: [HeadplaneResource: String] = [:]
    @Published private(set) var updated: [HeadplaneResource: Date] = [:]
    @Published private(set) var loading = Set<HeadplaneResource>()
    @Published private(set) var busy = false
    @Published private(set) var pending: HeadplaneResource?
    @Published var message: String?
    @Published var configurationError: String?
    private var client: (any HeadplaneAccess)?
    private var loaded = false
    private var reads: [HeadplaneResource: UUID] = [:]

    init(client: (any HeadplaneAccess)? = nil) { self.client = client; loaded = client != nil }
    func load() {
        guard !loaded else { return }
        do {
            connection = try HeadplaneCredentials.load()
            client = try connection.map { try HeadplaneClient(connection: $0) }
            loaded = true; configurationError = nil
        } catch { configurationError = "无法读取原有连接，请解锁后重试。原配置未改动。" }
    }
    func connect(_ draft: HeadplaneConnection) async throws {
        guard !busy, pending == nil, configurationError == nil else { throw HeadplaneFailure(message: "请先处理当前操作或配置读取错误。") }
        busy = true; defer { busy = false }
        let next = try draft.normalized(), candidate = try HeadplaneClient(connection: draft)
        let data = try await candidate.read(.machines)
        let parsed = try HeadplaneMachines(data)
        try Task.checkCancellation()
        try HeadplaneCredentials.save(next)
        clear(); connection = next; client = candidate; loaded = true
        machines = parsed; values[.machines] = data; updated[.machines] = .now
    }
    func disconnect() throws {
        guard !busy, pending == nil else { throw HeadplaneFailure(message: "请先核对当前操作结果。") }
        try HeadplaneCredentials.remove(); clear(); connection = nil; client = nil
    }
    private func clear() {
        revision = UUID(); machines = nil; policy = nil; agent = nil; keys = []; values = [:]; errors = [:]
        updated = [:]; loading = []; reads = [:]; message = nil; pending = nil
    }
    func refresh(_ resource: HeadplaneResource) async {
        guard let client, !loading.contains(resource) else { return }
        let ticket = revision, readID = UUID(); reads[resource] = readID; loading.insert(resource)
        defer { if ticket == revision && reads[resource] == readID { loading.remove(resource) } }
        do {
            let data = try await client.read(resource)
            try Task.checkCancellation()
            guard ticket == revision, reads[resource] == readID else { return }
            switch resource {
            case .machines: machines = try HeadplaneMachines(data)
            case .policy: policy = try HeadplanePolicy(data)
            case .keys:
                guard let groups = data["keys"].array else { throw HeadplaneFailure.incompatible }
                var result: [HeadplaneKey] = []
                for group in groups {
                    guard let items = group["preAuthKeys"].array else { throw HeadplaneFailure.incompatible }
                    result += try items.map { try HeadplaneKey($0, user: group["user"]) }
                }
                guard Set(result.map(\.id)).count == result.count else { throw HeadplaneFailure.incompatible }
                keys = result
            case .dns: guard data["baseDomain"].string != nil else { throw HeadplaneFailure.incompatible }
            case .agent: agent = try HeadplaneAgentStatus(data)
            case .login: break
            }
            values[resource] = data; updated[resource] = .now; errors[resource] = nil
            if resource == .keys, data["missing"].array?.isEmpty == false {
                errors[resource] = "部分用户的密钥未能读取，请重新刷新完整列表后核对操作结果。"
                return
            }
            if pending == resource { pending = nil; message = "已重新读取远端状态，请核对后再操作。" }
        } catch {
            guard ticket == revision, reads[resource] == readID, !Task.isCancelled else { return }
            errors[resource] = error.localizedDescription
        }
    }

    func mutate(_ resource: HeadplaneResource, revision expected: UUID, fields: [String: String], originalPolicy: String? = nil) async throws -> HeadplaneJSON {
        guard expected == revision else { throw HeadplaneFailure(message: "连接已改变，请关闭此页面后重新操作。") }
        guard let client, !busy, pending == nil else { throw HeadplaneFailure(message: "请先刷新核对当前操作结果。") }
        busy = true; defer { busy = false }
        do {
            if let originalPolicy {
                let latest = try HeadplanePolicy(await client.read(.policy))
                guard latest.writable else { throw HeadplaneFailure(message: "当前访问策略为只读。") }
                guard latest.text == originalPolicy else { throw HeadplaneFailure(message: "远端策略已被修改，请保留草稿并重新打开最新策略，合并后再保存。") }
            }
            let result = try await client.submit(resource, fields: fields)
            guard expected == revision else { throw HeadplaneFailure(message: "连接已改变，请核对原实例的操作结果。") }
            // Invalidate a pre-mutation poll so it cannot overwrite the confirmed new state.
            reads[resource] = UUID(); loading.remove(resource)
            pending = resource
            await refresh(resource)
            message = pending == nil ? nil : "请求已完成，但状态回查失败。请刷新核对。"
            return result
        } catch {
            if (error as? HeadplaneFailure)?.outcomeUnknown == true {
                reads[resource] = UUID(); loading.remove(resource)
                pending = resource
            }
            throw error
        }
    }
}
