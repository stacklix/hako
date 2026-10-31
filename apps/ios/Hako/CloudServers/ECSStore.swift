import Foundation
import Combine

enum ECSPage: String, CaseIterable { case overview = "概览", network = "网络", processes = "进程", terminal = "终端" }

protocol ECSReading: Sendable {
    func instance() async throws -> ECSInstance
    func monitor() async throws -> [ECSMonitorPoint]
    func snapshot(mode: String, pid: Int?) async throws -> ECSSnapshot
}
extension ECSClient: ECSReading { }

@MainActor final class ECSStore: ObservableObject {
    @Published private(set) var connection: ECSConnection?
    @Published private(set) var instance: ECSInstance?
    @Published private(set) var monitor: [ECSMonitorPoint] = []
    @Published private(set) var overview: ECSSnapshot?
    @Published private(set) var network: ECSSnapshot?
    @Published private(set) var processes: ECSSnapshot?
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var revision = UUID()
    private(set) var loaded = false
    private let readConnection: () throws -> ECSConnection?
    private let clientFactory: (ECSConnection) throws -> any ECSReading
    private var requests: [String: Task<Void, Never>] = [:]
    private var requestIDs: [String: UUID] = [:]
    private var issues: [String: String] = [:]

    init(connection: ECSConnection? = nil,
         readConnection: @escaping () throws -> ECSConnection? = { try ECSKeychain.load() },
         clientFactory: @escaping (ECSConnection) throws -> any ECSReading = { try ECSClient(connection: $0) }) {
        self.connection = connection; loaded = connection != nil
        self.readConnection = readConnection; self.clientFactory = clientFactory
    }

    func load() {
        guard !loaded else { return }
        do { connection = try readConnection()?.validated(); loaded = true; error = nil }
        catch { self.error = error.localizedDescription }
    }
    func configure(_ value: ECSConnection) throws {
        let value = try value.validated()
        try ECSKeychain.save(value)
        requests.values.forEach { $0.cancel() }; requests = [:]; requestIDs = [:]; issues = [:]
        revision = UUID(); connection = value; instance = nil; monitor = []
        overview = nil; network = nil; processes = nil; busy = false; error = nil; loaded = true
    }
    func refreshAll(includeOverview: Bool = true) async {
        await refreshResources(["instance", "monitor", "network", "processes"] + (includeOverview ? ["overview"] : []))
    }

    func pollUsage(interval: Duration = .seconds(3)) async {
        let clock = ContinuousClock()
        while !Task.isCancelled {
            let next = clock.now.advanced(by: interval)
            await refreshResources(["overview"])
            // Include request time in the interval and never overlap slow samples.
            do { try await clock.sleep(until: next) } catch { return }
        }
    }

    func refresh(_ page: ECSPage) async {
        switch page {
        case .overview: await refreshResources(["instance", "monitor", "overview"])
        case .network: await refreshResources(["monitor", "network"])
        case .processes: await refreshResources(["processes"])
        case .terminal: break
        }
    }

    private func refreshResources(_ resources: [String]) async {
        guard !Task.isCancelled else { return }
        load()
        guard let connection else { return }
        await withTaskGroup(of: Void.self) { group in
            for resource in resources {
                group.addTask { await self.refreshResource(resource, connection: connection) }
            }
        }
    }

    private func refreshResource(_ resource: String, connection: ECSConnection) async {
        guard !Task.isCancelled else { return }
        let task: Task<Void, Never>
        if let current = requests[resource], !current.isCancelled {
            task = current
        } else {
            let previous = requests[resource]
            let id = UUID(), ticket = revision
            requestIDs[resource] = id; busy = true
            task = Task { [weak self] in
                await previous?.value
                guard let self else { return }
                defer {
                    if self.requestIDs[resource] == id {
                        self.requests[resource] = nil; self.requestIDs[resource] = nil
                        self.busy = !self.requests.isEmpty
                    }
                }
                guard !Task.isCancelled, self.revision == ticket else { return }
                do {
                    let client = try self.clientFactory(connection)
                    var issue: String?
                    switch resource {
                    case "instance":
                        let value = try await client.instance()
                        try Task.checkCancellation(); guard self.revision == ticket else { return }
                        self.instance = value
                    case "monitor":
                        let value = try await client.monitor()
                        try Task.checkCancellation(); guard self.revision == ticket else { return }
                        self.monitor = value
                    default:
                        let value = try await client.snapshot(mode: resource, pid: nil)
                        try Task.checkCancellation(); guard self.revision == ticket else { return }
                        switch resource {
                        case "overview": self.overview = value
                        case "network": self.network = value
                        case "processes": self.processes = value
                        default: break
                        }
                        issue = value.socketError
                    }
                    self.issues[resource] = issue
                } catch is CancellationError { return }
                catch {
                    guard self.revision == ticket, !Task.isCancelled else { return }
                    self.issues[resource] = error.localizedDescription
                }
                self.error = self.issues.isEmpty ? nil : Set(self.issues.values).sorted().joined(separator: "\n")
            }
            requests[resource] = task
        }
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
}

enum ECSFormat {
    static func bytes(_ value: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, min(Double(Int64.max) - 1024, value.isFinite ? value : 0))), countStyle: .binary)
    }
    static func rate(_ value: Double) -> String { bytes(value) + "/s" }
    static func duration(_ seconds: Double) -> String {
        let total = Int(max(0, min(315_360_000, seconds.isFinite ? seconds : 0)))
        if total >= 86400 { return "\(total / 86400) 天 \(total % 86400 / 3600) 小时" }
        return "\(total / 3600) 小时 \(total % 3600 / 60) 分"
    }
}
