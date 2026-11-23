import Foundation
import Combine

enum RouterCredentials {
    private static let storage = SecureStorage.namespace("me.stackli.hako.router")
    static func load(storage: any SecretStorage = Self.storage) throws -> RouterConnection? {
        guard let data = try storage.read(account: "connection") else { return nil }
        return try JSONDecoder().decode(RouterConnection.self, from: data).normalized()
    }
    static func save(_ connection: RouterConnection, storage: any SecretStorage = Self.storage) throws {
        try storage.save(JSONEncoder().encode(connection.normalized()), account: "connection", accessibility: .whenUnlocked)
    }
    static func remove(storage: any SecretStorage = Self.storage) throws { try storage.delete(account: "connection") }
}

@MainActor final class RouterStore: ObservableObject {
    @Published private(set) var connection: RouterConnection?
    @Published private(set) var route: RouterRoute?
    @Published private(set) var snapshot: RouterSnapshot?
    @Published private(set) var updated: Date?
    @Published private(set) var busy = false
    @Published private(set) var pending = false
    @Published private(set) var fresh = false
    @Published private(set) var configurationError: String?
    @Published private(set) var resources: [RouterResource: RouterJSON] = [:]
    @Published private(set) var errors: [RouterResource: String] = [:]
    @Published private(set) var resourceDates: [RouterResource: Date] = [:]
    @Published private(set) var freshResources = Set<RouterResource>()
    @Published private(set) var deviceSpeedError: String?
    @Published private(set) var revision = UUID()
    @Published var message: String?
    private var client: (any RouterAccess)?
    private var loaded = false
    private var pendingResource: RouterResource?
    private var readingSpeeds = false
    private enum SpeedResult {
        case wan(RouterJSON)
        case devices(RouterSnapshot)
    }

    init(client: (any RouterAccess)? = nil) { self.client = client; loaded = client != nil }
    private static func makeClient(_ connection: RouterConnection) throws -> RouterClient {
        try RouterClient(connection: connection, isLocal: {
            try await Self.hostIsLocal()
        })
    }
    private static func hostIsLocal() async throws -> Bool {
        let network = LocalNetworkService.shared
        await network.refresh()
        try Task.checkCancellation()
        return network.isLocal
    }
    var writable: Bool { client != nil && fresh && !busy && !pending }
    var bindingsWritable: Bool { writable && snapshot?.routerMode == true }
    func value(_ resource: RouterResource) -> RouterJSON { resources[resource] ?? .null }
    func canEdit(_ resource: RouterResource) -> Bool { writable && freshResources.contains(resource) }

    func load() {
        guard !loaded else { return }
        do {
            let value = try RouterCredentials.load()
            client = try value.map { try Self.makeClient($0) }
            connection = value; loaded = true; configurationError = nil
        } catch { configurationError = "无法读取路由器配置，请解锁后重试。原有配置未改动。" }
    }

    func connect(_ draft: RouterConnection) async throws {
        guard !busy, !pending, configurationError == nil else { throw RouterFailure(message: "请先处理配置错误或核对上次操作结果。") }
        busy = true; defer { busy = false }
        let value = try draft.normalized(), next = try Self.makeClient(value)
        let snapshot = try await next.read()
        try Task.checkCancellation()
        try RouterCredentials.save(value)
        route = await next.currentRoute()
        client = next; connection = value; self.snapshot = snapshot
        resources = [:]; errors = [:]; resourceDates = [:]; freshResources = []
        deviceSpeedError = nil
        updated = .now; fresh = true; message = nil; revision = UUID()
    }

    func disconnect() throws {
        guard !busy, !pending else { throw RouterFailure(message: "请先刷新核对上次操作结果。") }
        try RouterCredentials.remove()
        route = nil
        client = nil; connection = nil; snapshot = nil; updated = nil; fresh = false; message = nil
        resources = [:]; errors = [:]; resourceDates = [:]; freshResources = []; revision = UUID()
        deviceSpeedError = nil
    }

    func refresh(_ requested: [RouterResource] = []) async {
        guard let client, !busy else { return }
        busy = true; defer { busy = false }
        do {
            let value = try await client.read()
            try Task.checkCancellation()
            snapshot = value; updated = .now; fresh = true; deviceSpeedError = nil
        } catch {
            guard !Task.isCancelled else { return }
            route = await client.currentRoute()
            fresh = false
            message = error.localizedDescription
            return
        }
        route = await client.currentRoute()
        var targets = requested
        if let pendingResource, !targets.contains(pendingResource) { targets.append(pendingResource) }
        for resource in targets {
            if Task.isCancelled { break }
            do {
                let value = try await client.read(resource)
                try Task.checkCancellation()
                resources[resource] = value
                errors[resource] = nil; resourceDates[resource] = .now; freshResources.insert(resource)
                if pendingResource == resource { pendingResource = nil }
            } catch {
                guard !Task.isCancelled else { return }
                errors[resource] = error.localizedDescription; freshResources.remove(resource)
            }
        }
        if pendingResource == nil {
            message = pending ? "已读取最新状态，请核对上次操作结果后继续。" : nil
            pending = false
        }
    }

    // Lightweight foreground polling must not toggle the full-page busy state
    // or resolve an outstanding mutation that still needs an explicit refresh.
    func refreshSpeeds(includeDevices: Bool) async {
        guard let client, fresh, !busy, !pending, !readingSpeeds, !Task.isCancelled else { return }
        readingSpeeds = true
        defer { readingSpeeds = false }
        let ticket = revision
        let previousDate = includeDevices ? updated : resourceDates[.wan]
        do {
            let result: SpeedResult
            if includeDevices { result = .devices(try await client.read()) }
            else { result = .wan(try await client.read(.wan)) }
            let currentRoute = await client.currentRoute()
            try Task.checkCancellation()
            guard ticket == revision, !busy, !pending,
                  (includeDevices ? updated : resourceDates[.wan]) == previousDate else { return }
            route = currentRoute
            switch result {
            case .wan(let value):
                resources[.wan] = value
                resourceDates[.wan] = .now
                errors[.wan] = nil
                freshResources.insert(.wan)
            case .devices(let value):
                snapshot = value
                updated = .now
                deviceSpeedError = nil
            }
        } catch {
            guard !Task.isCancelled, ticket == revision, !busy, !pending,
                  (includeDevices ? updated : resourceDates[.wan]) == previousDate else { return }
            if includeDevices { deviceSpeedError = error.localizedDescription }
            else {
                errors[.wan] = error.localizedDescription
                freshResources.remove(.wan)
            }
        }
    }

    func save(_ draft: RouterBindingDraft, replacing original: RouterBinding?) async throws {
        guard bindingsWritable, let client, let snapshot else { throw RouterFailure(message: "请先刷新状态；绑定管理仅在路由模式可用。") }
        let value = try draft.validated(in: snapshot, replacing: original?.id)
        try await mutate(send: { try await client.save(value, replacing: original) }, verify: { next in
            next.bindings.contains { $0.ip == value.ip && $0.mac == value.mac && $0.name == value.name }
        })
    }

    func remove(_ binding: RouterBinding) async throws {
        guard bindingsWritable, let client else { throw RouterFailure(message: "请先刷新状态；绑定管理仅在路由模式可用。") }
        try await mutate(send: { try await client.remove(binding) }, verify: { next in
            !next.bindings.contains { $0.id == binding.id }
        })
    }

    func changeDevice(_ device: RouterDevice, change: RouterDeviceChange) async throws {
        guard writable, let client else { throw RouterFailure(message: "请先刷新设备状态。") }
        try await mutate(send: { try await client.changeDevice(device, change: change) }, verify: { next in
            next.devices.first(where: { $0.mac == device.mac }).map(change.confirmed) == true
        })
    }

    func apply(_ change: RouterConfigurationChange) async throws {
        guard canEdit(change.resource), let client else { throw RouterFailure(message: "请先刷新此功能的配置。") }
        busy = true; defer { busy = false }
        do { try await client.apply(change); route = await client.currentRoute() }
        catch {
            route = await client.currentRoute()
            freshResources.remove(change.resource)
            if (error as? RouterFailure)?.outcomeUnknown == true { pending = true; pendingResource = change.resource; message = error.localizedDescription }
            throw error
        }
        pending = true; pendingResource = change.resource; freshResources.remove(change.resource)
        do {
            let next = try await client.read(change.resource)
            resources[change.resource] = next; resourceDates[change.resource] = .now
            guard change.confirmed(next) else { throw RouterFailure.incompatible }
            errors[change.resource] = nil; freshResources.insert(change.resource)
            pending = false; pendingResource = nil; message = nil
        } catch {
            message = "操作已提交，但状态尚未确认。请重新连接网络后刷新核对，勿重复保存。"
            throw RouterFailure(message: message!, outcomeUnknown: true)
        }
    }

    func wake(mac: String) async throws {
        guard writable, let client else { throw RouterFailure(message: "请先刷新设备状态。") }
        busy = true; defer { busy = false }
        do { try await client.wake(mac: mac); route = await client.currentRoute(); message = "已提交唤醒请求；请刷新设备列表确认目标是否在线。" }
        catch { route = await client.currentRoute(); if (error as? RouterFailure)?.outcomeUnknown == true { pending = true; message = error.localizedDescription }; throw error }
    }
    func reboot() async throws {
        guard writable, let client else { throw RouterFailure(message: "请先刷新路由器状态。") }
        busy = true; defer { busy = false }
        do { try await client.reboot(); route = await client.currentRoute() }
        catch { route = await client.currentRoute(); if (error as? RouterFailure)?.outcomeUnknown == true { pending = true; fresh = false; message = error.localizedDescription }; throw error }
        pending = true; fresh = false
        message = "路由器已接收重启请求，请等待网络恢复后刷新确认。"
    }

    private func mutate(send: () async throws -> Void, verify: (RouterSnapshot) -> Bool) async throws {
        busy = true; defer { busy = false }
        do { try await send(); route = await client?.currentRoute() }
        catch {
            route = await client?.currentRoute()
            fresh = false
            if (error as? RouterFailure)?.outcomeUnknown == true { pending = true; message = error.localizedDescription }
            throw error
        }
        pending = true; fresh = false
        do {
            guard let client else { throw RouterFailure.incompatible }
            let next = try await client.read()
            route = await client.currentRoute()
            snapshot = next; updated = .now
            guard verify(next) else {
                throw RouterFailure(message: "路由器已响应，但回查状态与预期不一致，请刷新核对。", outcomeUnknown: true)
            }
            pending = false; fresh = true; message = nil
        } catch {
            route = await client?.currentRoute()
            message = "操作已提交，尚未确认最终状态。请刷新核对后再操作。"
            throw RouterFailure(message: message!, outcomeUnknown: true)
        }
    }
}
