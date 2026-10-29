import Foundation
import Combine

@MainActor final class ArcaneHostData: ObservableObject {
    typealias Consumer = @Sendable (Data) async throws -> Void
    typealias InfoReader = (ArcaneClient, String) async throws -> ArcaneHostInfo
    typealias StatsReader = (ArcaneClient, String, @escaping Consumer) async throws -> Void
    @Published private(set) var info: ArcaneHostInfo?
    @Published private(set) var sample: ArcaneHostStats?
    @Published private(set) var infoLoading = false
    @Published private(set) var connected = false
    @Published private(set) var infoError: String?
    @Published private(set) var streamError: String?
    @Published private(set) var sampledAt: Date?
    private var context = ""
    private var infoTicket: UUID?
    private var streamTicket: UUID?
    private let readInfo: InfoReader
    private let readStats: StatsReader

    init(readInfo: @escaping InfoReader = { try await $0.hostInfo($1) },
         readStats: @escaping StatsReader = { try await $0.hostStats($1, consume: $2) }) {
        self.readInfo = readInfo; self.readStats = readStats
    }

    private func prepare(client: ArcaneClient, environment: String) {
        let next = client.connection.id + ":" + environment
        guard next != context else { return }
        context = next; infoTicket = nil; streamTicket = nil
        info = nil; sample = nil; sampledAt = nil
        infoError = nil; streamError = nil; connected = false; infoLoading = false
    }

    func refresh(client: ArcaneClient, environment: String) async {
        prepare(client: client, environment: environment)
        let ticket = UUID(); infoTicket = ticket; infoLoading = true; infoError = nil
        defer { if infoTicket == ticket { infoLoading = false } }
        do {
            let value = try await readInfo(client, environment)
            try Task.checkCancellation()
            guard infoTicket == ticket else { return }
            info = value
        } catch is CancellationError { }
        catch { if infoTicket == ticket { infoError = error.localizedDescription } }
    }

    // Retry interrupted read-only subscriptions, but don't loop on permission or
    // missing-route errors. Leaving the page cancels both the socket and retry.
    func observe(client: ArcaneClient, environment: String) async {
        prepare(client: client, environment: environment)
        let ticket = UUID(); streamTicket = ticket; connected = false; streamError = nil
        defer { if streamTicket == ticket { connected = false } }
        while !Task.isCancelled && streamTicket == ticket {
            do {
                try await readStats(client, environment) { [weak self] bytes in
                    let sample = try ArcaneHostStats.parse(bytes)
                    await self?.receive(sample, ticket: ticket)
                }
                if !Task.isCancelled, streamTicket == ticket { streamError = "主机资源连接已结束，正在重新连接。" }
            } catch {
                guard !Task.isCancelled, streamTicket == ticket else { return }
                connected = false; streamError = error.localizedDescription
                if let status = (error as? ArcaneFailure)?.status, [401, 403, 404].contains(status) { return }
            }
            guard !Task.isCancelled, streamTicket == ticket else { return }
            connected = false
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
        }
    }

    private func receive(_ sample: ArcaneHostStats, ticket: UUID) {
        guard streamTicket == ticket else { return }
        self.sample = sample; sampledAt = .now; connected = true; streamError = nil
    }
    func fail(_ error: Error) {
        infoError = error.localizedDescription; streamError = error.localizedDescription; connected = false
    }
}
