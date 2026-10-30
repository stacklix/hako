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
    @Published private(set) var verifyingOperation = false
    @Published private(set) var fileSaveRunning = false
    @Published private(set) var terminalSessionID: UUID?
    @Published private(set) var activeOperation: ArcanePendingOperation?
    @Published private(set) var operationMessage: String?
    @Published private(set) var operationLogs: [String] = []
    @Published private(set) var lastChange: ArcaneContainerChange?
    private var configurationLoaded = false
    private var actionTask: Task<Void, Never>?
    private var refreshTicket: UUID?
    private var verificationTask: Task<Void, Never>?
    private var verificationTicket: UUID?
    private var cachedClient: ArcaneClient?
    private let defaults: UserDefaults
    private let clientFactory: (ArcaneConnection) throws -> ArcaneClient
    private static let pendingKey = "arcane.pending-operation"
    var environment: ArcaneEnvironment? { environments.first { $0.id == environmentID } }
    var environmentName: String { environment?.displayName ?? environmentID }

    func operationStatus(environmentID: String, containerID: String) -> ArcaneOperationStatus? {
        guard let operation = activeOperation ?? pending,
              operation.connectionID == connection?.id, operation.environmentID == environmentID else { return nil }
        let replacement = lastChange.flatMap { change in
            change.environmentID == environmentID && change.originalID == operation.containerID ? change.replacementID : nil
        }
        guard operation.containerID == containerID || replacement == containerID else { return nil }
        return ArcaneOperationStatus(action: operation.action, running: operationRunning)
    }

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
        guard pending == nil, !operationRunning, !fileSaveRunning, terminalSessionID == nil else { throw ArcaneFailure(message: "请先关闭终端并等待当前操作完成，再修改连接。") }
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
            verifyPendingRestart(client: client, environment: id)
        } catch is CancellationError { }
        catch { if self.connection?.id == connection.id && refreshTicket == ticket { self.error = error.localizedDescription } }
    }

    func start(_ action: ArcaneAction, container: ArcaneContainerDetails, environment: ArcaneEnvironment) {
        guard pending == nil, !operationRunning, !fileSaveRunning, terminalSessionID == nil else { return }
        if let reason = container.blockedReason(for: action) { operationMessage = reason; return }
        do {
            let client = try client()
            let operation = ArcanePendingOperation(connectionID: client.connection.id, environmentID: environment.id,
                environmentName: environment.displayName, containerID: container.id, containerName: container.displayName,
                action: action, previousStartedAt: container.state?.startedAt)
            // Persist before sending: app termination or background suspension must not cause an automatic retry.
            defaults.set(try JSONEncoder().encode(operation), forKey: Self.pendingKey)
            pending = operation; activeOperation = operation; operationRunning = true
            lastChange = nil
            operationMessage = "正在\(action.title)：\(operation.containerName)"
            operationLogs = []
            actionTask = Task {
                let baseline = try? await client.activities(operation.environmentID)
                let observer = Task {
                    if let baseline { await observeOperation(operation, client: client, baseline: Set(baseline.map(\.id))) }
                }
                defer {
                    observer.cancel(); operationRunning = false; activeOperation = nil; actionTask = nil
                    verifyPendingRestart(client: client, environment: operation.environmentID)
                }
                do {
                    let newID = try await client.perform(action, environment: operation.environmentID, id: operation.containerID)
                    // A successful mutation response confirms completion; activity progress alone never does.
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

    func withFileSave(_ action: () async throws -> Void) async throws {
        guard !operationRunning, !fileSaveRunning, pending == nil, terminalSessionID == nil else {
            throw ArcaneFailure(message: "请先等待或核对当前操作，再保存文件。")
        }
        fileSaveRunning = true
        defer { fileSaveRunning = false }
        try await action()
    }

    func beginTerminalSession() throws -> UUID {
        guard !operationRunning, !fileSaveRunning, pending == nil, terminalSessionID == nil else {
            throw ArcaneFailure(message: "请先关闭其他终端，或等待并核对当前操作。")
        }
        let token = UUID(); terminalSessionID = token; return token
    }

    func endTerminalSession(_ token: UUID) {
        if terminalSessionID == token { terminalSessionID = nil }
    }

    func acknowledgeUnknownOperation() {
        guard !operationRunning else { return }
        clearPending()
        operationMessage = nil; operationLogs = []
    }

    private func clearPending() {
        pending = nil
        defaults.removeObject(forKey: Self.pendingKey)
        verificationTicket = nil
        verificationTask?.cancel(); verificationTask = nil
        verifyingOperation = false
    }

    private func verifyPendingRestart(client: ArcaneClient, environment: String) {
        guard !operationRunning, verificationTask == nil, let operation = pending, operation.action == .restart,
              operation.connectionID == client.connection.id, operation.environmentID == environment else { return }
        let ticket = UUID(); verificationTicket = ticket; verifyingOperation = true
        verificationTask = Task {
            defer {
                if verificationTicket == ticket { verificationTask = nil; verificationTicket = nil; verifyingOperation = false }
            }
            do {
                let details = try await client.details(operation.environmentID, id: operation.containerID)
                guard !Task.isCancelled, verificationTicket == ticket, pending?.id == operation.id,
                      connection?.id == operation.connectionID, !operationRunning,
                      operation.restartObserved(in: details) else { return }
                clearPending()
                operationMessage = "已核对：\(operation.containerName) 的启动时间已更新，当前运行中。"
            } catch { } // Keep the record if status cannot be read or doesn't prove a restart.
        }
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
