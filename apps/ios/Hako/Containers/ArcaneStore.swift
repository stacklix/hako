import Foundation
import Combine

struct ArcaneContainerChange {
    var id = UUID()
    let environmentID: String
    let originalID: String
    let replacementID: String?
}

@MainActor final class ArcaneStore: ObservableObject {
    static let shared = ArcaneStore()
    @Published private(set) var connection: ArcaneConnection?
    @Published private(set) var environments: [ArcaneEnvironment] = []
    @Published private(set) var environmentID = ""
    @Published private(set) var containers: [ArcaneContainer] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var updatedAt: Date?
    @Published private(set) var pending: ArcanePendingOperation?
    @Published private(set) var operationRunning = false
    @Published private(set) var operationMessage: String?
    @Published private(set) var operationLogs: [String] = []
    @Published private(set) var operationProgress: Int?
    @Published private(set) var lastChange: ArcaneContainerChange?
    private var configurationLoaded = false
    private var actionTask: Task<Void, Never>?
    private var refreshTicket: UUID?
    private var cachedClient: ArcaneClient?
    private let defaults: UserDefaults
    private let clientFactory: (ArcaneConnection) throws -> ArcaneClient
    private static let pendingKey = "arcane.pending-operation"
    var environment: ArcaneEnvironment? { environments.first { $0.id == environmentID } }
    var environmentName: String { environment?.displayName ?? environmentID }

    init(connection: ArcaneConnection? = nil, defaults: UserDefaults = .standard,
         clientFactory: @escaping (ArcaneConnection) throws -> ArcaneClient = { try ArcaneClient(connection: $0) }) {
        self.connection = connection
        self.defaults = defaults
        self.clientFactory = clientFactory
        configurationLoaded = connection != nil
        if let data = defaults.data(forKey: Self.pendingKey) {
            pending = try? JSONDecoder().decode(ArcanePendingOperation.self, from: data)
            if pending != nil { operationMessage = "上次操作的结果尚未确认，请刷新状态并核对 Arcane 活动记录。" }
        }
    }

    func loadConfiguration() {
        guard !configurationLoaded else { return }
        do {
            connection = try ArcaneKeychain.load()
            configurationLoaded = true
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func configure(_ value: ArcaneConnection) throws {
        guard pending == nil, !operationRunning else { throw ArcaneFailure(message: "请先核对或等待当前容器操作完成，再修改连接。") }
        var normalized = try value.normalized()
        if let connection, connection.address != normalized.address || connection.apiKey != normalized.apiKey || connection.allowHTTP != normalized.allowHTTP {
            normalized.id = UUID().uuidString
        }
        try ArcaneKeychain.save(normalized)
        connection = normalized
        cachedClient = nil
        configurationLoaded = true
        containers = []; environments = []; environmentID = ""; updatedAt = nil; error = nil
        operationMessage = nil; operationLogs = []; lastChange = nil
        refreshTicket = nil; loading = false
    }

    func client() throws -> ArcaneClient {
        guard let connection else { throw ArcaneFailure(message: "请先配置 Arcane 连接。") }
        if let cachedClient { return cachedClient }
        let client = try clientFactory(connection)
        cachedClient = client
        return client
    }

    func selectEnvironment(_ id: String) {
        guard id != environmentID, environments.contains(where: { $0.id == id }) else { return }
        environmentID = id
        containers = []; updatedAt = nil; error = nil
        refreshTicket = nil; loading = false
        if let connection { defaults.set(id, forKey: "arcane.environment." + connection.id) }
    }

    func refresh(forceEnvironments: Bool = false) async {
        loadConfiguration()
        guard let connection else { return }
        let ticket = UUID()
        refreshTicket = ticket
        loading = true
        defer { if refreshTicket == ticket { loading = false } }
        do {
            let client = try client()
            if environments.isEmpty || forceEnvironments {
                let environments = try await client.environments()
                try Task.checkCancellation()
                guard self.connection?.id == connection.id, refreshTicket == ticket else { return }
                self.environments = environments
                if !environments.contains(where: { $0.id == environmentID }) {
                    let stored = defaults.string(forKey: "arcane.environment." + connection.id)
                    environmentID = environments.first(where: { $0.id == stored })?.id
                        ?? environments.first(where: { $0.id == "0" })?.id ?? environments.first?.id ?? ""
                    containers = []; updatedAt = nil
                }
            }
            guard !environmentID.isEmpty else { error = "当前 API Key 没有可访问的 Docker 环境。"; return }
            let id = environmentID
            let containers = try await client.containers(id)
            try Task.checkCancellation()
            guard self.connection?.id == connection.id, environmentID == id, refreshTicket == ticket else { return }
            self.containers = containers
            updatedAt = Date(); error = nil
        } catch is CancellationError { }
        catch { if self.connection?.id == connection.id && refreshTicket == ticket { self.error = error.localizedDescription } }
    }

    func start(_ action: ArcaneAction, container: ArcaneContainerDetails, environment: ArcaneEnvironment) {
        guard pending == nil, !operationRunning else { return }
        do {
            let client = try client()
            let operation = ArcanePendingOperation(connectionID: client.connection.id, environmentID: environment.id,
                environmentName: environment.displayName, containerID: container.id, containerName: container.displayName, action: action)
            // Persist before sending: app termination or background suspension must not cause an automatic retry.
            defaults.set(try JSONEncoder().encode(operation), forKey: Self.pendingKey)
            pending = operation; operationRunning = true
            operationMessage = "正在\(action.title)：\(operation.containerName)"
            operationLogs = []; operationProgress = nil
            actionTask = Task {
                let baseline = try? await client.activities(operation.environmentID)
                let observer = Task {
                    if let baseline { await observeOperation(operation, client: client, baseline: Set(baseline.map(\.id))) }
                }
                defer { observer.cancel(); operationRunning = false; operationProgress = nil; actionTask = nil }
                do {
                    let newID = try await client.perform(action, environment: operation.environmentID, id: operation.containerID)
                    // Only the mutation response confirms success; progress events alone never do.
                    clearPending()
                    operationMessage = "\(action.title)已完成：\(operation.containerName)"
                    lastChange = ArcaneContainerChange(environmentID: operation.environmentID, originalID: operation.containerID, replacementID: newID)
                    await refresh()
                } catch {
                    operationMessage = error.localizedDescription
                    if (error as? ArcaneFailure)?.outcomeUnknown != true { clearPending() }
                }
            }
        } catch { operationMessage = error.localizedDescription }
    }

    func acknowledgeUnknownOperation() {
        guard !operationRunning else { return }
        clearPending()
        operationMessage = nil; operationLogs = []
    }

    private func clearPending() {
        pending = nil
        defaults.removeObject(forKey: Self.pendingKey)
    }

    private func observeOperation(_ operation: ArcanePendingOperation, client: ArcaneClient, baseline: Set<String>) async {
        var activityID: String?
        while !Task.isCancelled, operationRunning, pending?.id == operation.id {
            do {
                if activityID == nil {
                    let activities = try await client.activities(operation.environmentID)
                    activityID = activities.first { !baseline.contains($0.id) && $0.resourceId == operation.containerID && $0.type == "container_" + operation.action.rawValue }?.id
                }
                if let activityID {
                    let detail = try await client.activity(operation.environmentID, id: activityID)
                    guard !Task.isCancelled, pending?.id == operation.id else { return }
                    operationProgress = detail.activity.progress.map { min(100, max(0, $0)) }
                    operationLogs = (detail.messages ?? []).suffix(100).map { client.redacted($0.message) }
                }
                try await Task.sleep(for: .seconds(2))
            } catch { return } // Activity permission is optional; never block or retry the mutation.
        }
    }
}

@MainActor final class ArcaneContainerData: ObservableObject {
    @Published private(set) var details: ArcaneContainerDetails?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private var refreshTicket: UUID?

    func reset() {
        refreshTicket = nil
        details = nil; loading = false; error = nil
    }

    // A new visible-page task supersedes a cancelled request immediately. Old
    // completions cannot clear its loading state or replace its data/errors.
    func refresh(client: ArcaneClient, environment: String, container: String) async -> ArcaneContainerDetails? {
        let ticket = UUID()
        refreshTicket = ticket
        loading = true
        defer { if refreshTicket == ticket { loading = false } }
        do {
            let value = try await client.details(environment, id: container)
            try Task.checkCancellation()
            guard refreshTicket == ticket else { return nil }
            details = value; error = nil
            return value
        } catch is CancellationError { }
        catch { if refreshTicket == ticket { self.error = error.localizedDescription } }
        return nil
    }
}

struct ArcaneLogLine: Identifiable {
    let id: Int
    let text: String
}

@MainActor final class ArcaneLiveData: ObservableObject {
    @Published private(set) var sample: ArcaneResourceSample?
    @Published private(set) var sampleAt: Date?
    @Published private(set) var networkTraffic: ArcaneNetworkTraffic?
    @Published private(set) var statsError: String?
    @Published private(set) var logs: [ArcaneLogLine] = []
    @Published private(set) var logsError: String?
    @Published private(set) var logsConnected = false
    private var nextLine = 0
    private var statsGeneration = UUID()
    private var logsGeneration = UUID()
    private var previousStats: (sample: ArcaneResourceSample, receivedAt: Date)?

    func reset() {
        sample = nil; sampleAt = nil; statsError = nil
        previousStats = nil; networkTraffic = nil
        logs = []; logsError = nil; logsConnected = false
        statsGeneration = UUID(); logsGeneration = UUID()
    }

    func stats(client: ArcaneClient, environment: String, container: String) async {
        let generation = UUID()
        statsGeneration = generation
        previousStats = nil; networkTraffic = nil
        statsError = nil
        do {
            try await client.stream(environment, id: container, kind: "stats") { [weak self] data in
                let sample = try ArcaneResourceSample.parse(data)
                await self?.setSample(sample, generation: generation)
            }
        } catch is CancellationError { }
        catch { if !Task.isCancelled && statsGeneration == generation { statsError = error.localizedDescription } }
    }

    func logStream(client: ArcaneClient, environment: String, container: String) async {
        let generation = UUID()
        logsGeneration = generation
        logs = []
        logsError = nil; logsConnected = false
        defer { if logsGeneration == generation { logsConnected = false } }
        do {
            try await client.stream(environment, id: container, kind: "logs") { [weak self] data in
                let lines = try ArcaneLogDecoder.lines(data).map { client.redacted($0) }
                await self?.append(lines, generation: generation)
            }
        } catch is CancellationError { }
        catch { if !Task.isCancelled && logsGeneration == generation { logsError = error.localizedDescription } }
    }

    private func setSample(_ value: ArcaneResourceSample, generation: UUID) {
        guard statsGeneration == generation, !Task.isCancelled else { return }
        let now = Date()
        let elapsed: TimeInterval
        if let before = previousStats?.sample.sourceDate, let after = value.sourceDate { elapsed = after.timeIntervalSince(before) }
        else { elapsed = previousStats.map { now.timeIntervalSince($0.receivedAt) } ?? 0 }
        networkTraffic = ArcaneNetworkTraffic(previous: previousStats?.sample, current: value, elapsed: elapsed)
        previousStats = (value, now)
        sample = value; sampleAt = now
    }

    private func append(_ values: [String], generation: UUID) {
        guard logsGeneration == generation, !Task.isCancelled else { return }
        logsConnected = true
        for text in values {
            logs.append(ArcaneLogLine(id: nextLine, text: String(text.prefix(8_192))))
            nextLine += 1
        }
        if logs.count > 500 { logs.removeFirst(logs.count - 500) }
        while logs.reduce(0, { $0 + $1.text.utf8.count }) > 524_288, logs.count > 1 { logs.removeFirst() }
    }
}
