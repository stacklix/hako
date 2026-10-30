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
    private var refreshTask: Task<Void, Never>?
    private var refreshPage: ECSPage?
    private var refreshID: UUID?

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
        refreshTask?.cancel(); refreshTask = nil; refreshID = nil; refreshPage = nil
        revision = UUID(); connection = value; instance = nil; monitor = []
        overview = nil; network = nil; processes = nil; busy = false; error = nil; loaded = true
    }
    func refresh(_ page: ECSPage) async {
        guard !Task.isCancelled, page != .terminal else { return }
        load()
        guard let connection else { return }
        let task: Task<Void, Never>
        if let current = refreshTask, !current.isCancelled, refreshPage == page {
            task = current
        } else {
            let previous = refreshTask
            previous?.cancel()
            let id = UUID(), ticket = revision
            refreshID = id; refreshPage = page; busy = true; error = nil
            task = Task { [weak self] in
                // Finish cancelling the old page before querying the new page.
                // A busy old request must never make the new page sleep for 30s.
                await previous?.value
                guard let self else { return }
                defer {
                    if self.refreshID == id {
                        self.refreshTask = nil; self.refreshID = nil; self.refreshPage = nil; self.busy = false
                    }
                }
                guard !Task.isCancelled, self.revision == ticket, self.refreshID == id else { return }
                await self.fetch(page, connection: connection, ticket: ticket, id: id)
            }
            refreshTask = task
        }
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private func fetch(_ page: ECSPage, connection: ECSConnection, ticket: UUID, id: UUID) async {
        do {
            let client = try clientFactory(connection)
            var issues: [String] = []
            if page == .overview || instance == nil {
                do {
                    let value = try await client.instance()
                    try Task.checkCancellation(); guard ticket == revision, refreshID == id else { return }
                    instance = value
                } catch is CancellationError { throw CancellationError() }
                catch { issues.append(error.localizedDescription) }
            }
            if page == .overview || page == .network {
                try Task.checkCancellation()
                do {
                    let values = try await client.monitor()
                    try Task.checkCancellation(); guard ticket == revision, refreshID == id else { return }
                    monitor = values
                } catch is CancellationError { throw CancellationError() }
                catch { issues.append(error.localizedDescription) }
            }
            try Task.checkCancellation()
            do {
                let mode: String
                switch page { case .overview: mode = "overview"; case .network: mode = "network"; case .processes: mode = "processes"; case .terminal: return }
                let value = try await client.snapshot(mode: mode, pid: nil)
                try Task.checkCancellation(); guard ticket == revision, refreshID == id else { return }
                switch page { case .overview: overview = value; case .network: network = value; case .processes: processes = value; case .terminal: break }
                if let socketError = value.socketError { issues.append(socketError) }
            } catch is CancellationError { throw CancellationError() }
            catch { issues.append(error.localizedDescription) }
            guard ticket == revision, refreshID == id else { return }
            error = issues.isEmpty ? nil : Array(Set(issues)).sorted().joined(separator: "\n")
        } catch is CancellationError { }
        catch { if ticket == revision, refreshID == id { self.error = error.localizedDescription } }
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
