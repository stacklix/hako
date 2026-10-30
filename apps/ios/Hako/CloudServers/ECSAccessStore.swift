import Foundation
import Combine

@MainActor final class ECSAccessStore: ObservableObject {
    @Published private(set) var summary: ECSAccessSummary?
    @Published private(set) var rankings: ECSAccessRankings?
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    private var ticket = UUID()
    private var loadedContext = ""
    private var lastHour: String?

    func clear() {
        ticket = UUID(); loadedContext = ""; lastHour = nil; summary = nil; rankings = nil; error = nil; busy = false
    }

    func refresh(connection: ECSConnection, client: ConsoleClient, range: ECSAccessRange = .day,
                 domain: String = "", hour: String? = nil) async {
        let id = UUID(); ticket = id
        let context = "\(connection.region)|\(connection.instanceID)|\(client.serverURL)|\(client.username)|\(client.authenticated)|\(client.logoutPending)|\(range.rawValue)|\(domain)|\(UserDefaults.standard.string(forKey: "ecs.access.revision") ?? "")"
        let selectionChanged = context == loadedContext && lastHour != hour
        lastHour = hour
        if context != loadedContext { summary = nil; rankings = nil; loadedContext = context }
        if selectionChanged { rankings = nil }
        error = nil; busy = true
        defer { if ticket == id { busy = false } }
        do {
            guard let binding = ECSAccessBinding.load(connection), !binding.domains.isEmpty else { return }
            guard binding.matches(origin: client.serverURL, account: client.username) else {
                throw HakoError(message: "Hako 服务器或账号已切换，请重新关联访问统计域名。")
            }
            guard domain.isEmpty || binding.domains.contains(domain) else { return }
            let value: ECSAccessSummary
            if selectionChanged, let current = summary { value = current }
            else { value = try await client.accessLogs(ECSAccessSummary.self, range: range, domain: domain) }
            try Task.checkCancellation()
            guard ticket == id else { return }
            guard value.status.enabled, !domain.isEmpty, let from = value.from, let to = value.to else {
                summary = value; rankings = nil
                return
            }
            let ranks = try await client.accessLogs(ECSAccessRankings.self, rankings: true,
                range: range, domain: domain, from: from, to: to, hour: hour)
            try Task.checkCancellation()
            guard ticket == id else { return }
            summary = value; rankings = ranks
        } catch is CancellationError { }
        catch {
            guard ticket == id else { return }
            self.error = error.localizedDescription
            HakoLog.record(.cloudServers, .error, "访问统计读取失败", detail: error.localizedDescription)
        }
    }
}
