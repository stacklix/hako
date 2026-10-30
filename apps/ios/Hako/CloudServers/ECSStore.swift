import Foundation
import Combine

enum ECSPage: String, CaseIterable { case overview = "概览", network = "网络", processes = "进程", terminal = "终端" }

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

    func load() {
        guard !loaded else { return }
        do { connection = try ECSKeychain.load()?.validated(); loaded = true; error = nil }
        catch { self.error = error.localizedDescription }
    }
    func configure(_ value: ECSConnection) throws {
        let value = try value.validated()
        try ECSKeychain.save(value)
        revision = UUID(); connection = value; instance = nil; monitor = []
        overview = nil; network = nil; processes = nil; busy = false; error = nil; loaded = true
    }
    func refresh(_ page: ECSPage) async {
        guard let connection, !busy, page != .terminal else { return }
        let ticket = revision
        busy = true; error = nil
        defer { if revision == ticket { busy = false } }
        do {
            let client = try ECSClient(connection: connection)
            var issues: [String] = []
            if page == .overview || instance == nil {
                do {
                    let value = try await client.instance()
                    try Task.checkCancellation(); guard ticket == revision else { return }
                    instance = value
                } catch is CancellationError { throw CancellationError() }
                catch { issues.append(error.localizedDescription) }
            }
            if page == .overview || page == .network {
                do {
                    let values = try await client.monitor()
                    try Task.checkCancellation(); guard ticket == revision else { return }
                    monitor = values
                } catch is CancellationError { throw CancellationError() }
                catch { issues.append(error.localizedDescription) }
            }
            do {
                let mode: String
                switch page { case .overview: mode = "overview"; case .network: mode = "network"; case .processes: mode = "processes"; case .terminal: return }
                let value = try await client.snapshot(mode: mode)
                try Task.checkCancellation(); guard ticket == revision else { return }
                switch page { case .overview: overview = value; case .network: network = value; case .processes: processes = value; case .terminal: break }
                if let socketError = value.socketError { issues.append(socketError) }
            } catch is CancellationError { throw CancellationError() }
            catch { issues.append(error.localizedDescription) }
            guard ticket == revision else { return }
            error = issues.isEmpty ? nil : Array(Set(issues)).sorted().joined(separator: "\n")
        } catch is CancellationError { }
        catch { if ticket == revision { self.error = error.localizedDescription } }
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
