import Foundation
import Combine

@MainActor final class DeviceMonitorClient: ObservableObject {
    static let shared = DeviceMonitorClient()
    private let authentication: any AuthenticatedServerAccess
    private let socket: AgentRequestSocket
    private let defaults: UserDefaults
    private var subscription: AnyCancellable?
    private struct State {
        var context = ""
        var inventory = DeviceMonitorInventory()
        var deviceData: [String: ConsoleDeviceData] = [:]
        var httpChecks: [String: ConsoleHTTPCheckState] = [:]
        var message: String?
    }
    @Published private var state = State()
    @Published private var working = false
    init(authentication: (any AuthenticatedServerAccess)? = nil, defaults: UserDefaults = .standard) {
        let authentication = authentication ?? AuthenticatedServerService.shared
        self.authentication = authentication
        self.defaults = defaults
        self.socket = AgentRequestSocket(authentication: authentication, logSource: .devices)
        subscription = authentication.changes.sink { [weak self] _ in
            self?.objectWillChange.send()
            Task { @MainActor [weak self] in self?.socket.resetIfContextChanged() }
        }
    }
    var serverURL: String { authentication.serverURL }
    var username: String { authentication.username }
    var authenticated: Bool { authentication.authenticated }
    var hasSavedSession: Bool { authentication.hasSavedSession }
    var logoutPending: Bool { authentication.logoutPending }
    var busy: Bool { working || authentication.busy }
    var requestContext: String { authentication.requestContext }
    private var inventoryStorage: DeviceMonitorInventory.Storage {
        .init(server: serverURL, account: username, defaults: defaults)
    }
    private var current: State {
        state.context == requestContext ? state : State(context: requestContext, inventory: inventoryStorage.load())
    }
    private func prepareContext() { if state.context != requestContext { state = current } }
    var agents: [ConsoleAgent] {
        get { current.inventory.agents }
        set { prepareContext(); state.inventory.agents = newValue; inventoryStorage.save(state.inventory) }
    }
    var hasFetchedAgents: Bool { current.inventory.hasFetched }
    func selectedAgent(id: String?) -> ConsoleAgent? { current.inventory.selectedAgent(id: id) }
    private func markOffline(agentID: String? = nil) {
        prepareContext()
        state.inventory.markOffline(agentID: agentID)
    }
    var deviceData: [String: ConsoleDeviceData] {
        get { current.deviceData }
        set { prepareContext(); state.deviceData = newValue }
    }
    var httpChecks: [String: ConsoleHTTPCheckState] {
        get { current.httpChecks }
        set { prepareContext(); state.httpChecks = newValue }
    }
    var message: String? {
        get {
            current.message ?? (hasSavedSession && !authenticated
                ? "暂时无法验证服务器连接，请检查网络后重试。" : authentication.message)
        }
        set { prepareContext(); state.message = newValue }
    }
    func restore() async { await authentication.restore() }
    private func authorized(_ type: String, agentID: String? = nil, body: [String: Any]? = nil) async throws -> Data {
        let context = requestContext
        do {
            let data = try await socket.send(type, agentID: agentID, body: body)
            guard context == requestContext else { throw CancellationError() }
            return data
        } catch let error as ServerHTTPError {
            guard context == requestContext else { throw CancellationError() }
            let text: String?
            switch error.code {
            case "agent_offline", "agent_disconnected":
                markOffline(agentID: agentID)
                text = "设备当前离线，等待设备重新连接。"
            case "agent_timeout": text = "设备响应超时，动作可能仍在执行，请先确认结果。"
            case "unsupported_method": text = "设备不支持此动作，请刷新设备列表。"
            case "duplicate_agent": text = "此公钥已登记，请刷新设备列表查看对应设备。"
            case "device_id_unavailable": text = "服务器暂时无法分配设备 ID，请稍后重试。"
            case "invalid_public_key_or_device": text = "设备名称或 RSA 公钥无效，请使用 Agent 导出的 RSA 2048–8192 位公钥，并确认服务端已更新。"
            case "agent_busy": text = "设备繁忙，请稍后重试。"
            case "socket_unavailable": text = "服务端尚不支持设备 WebSocket，请先更新服务端。"
            default: text = nil
            }
            if let text { throw HakoError(message: text) }
            throw error
        } catch {
            guard context == requestContext else { throw CancellationError() }
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            if error is URLError { markOffline() }
            throw error
        }
    }
    private func execute(_ action: () async throws -> Void) async {
        guard !busy else { return }
        let context = requestContext
        working = true; message = nil
        defer { working = false }
        do { try await action() }
        catch is CancellationError { }
        catch {
            guard context == requestContext else { return }
            markOffline()
            message = DeviceMonitorFailure.message(for: error)
        }
    }
    @discardableResult func fetchAgents() async -> Bool {
        var fetched = false
        await execute {
            try await self.fetchAgentsInternal()
            fetched = true
        }
        return fetched
    }

    func addAgent(name: String, publicKeyPEM: String) async throws {
        guard !busy else { throw HakoError(message: "正在处理其他请求，请稍后重试。") }
        guard authenticated, !logoutPending else { throw HakoError(message: "请先登录 Hako 服务器。") }
        let registration = try ConsoleAgentRegistration(name: name, publicKeyPEM: publicKeyPEM)
        working = true; message = nil
        defer { working = false }
        let response: Data
        do {
            response = try await authorized("register", body: registration.body)
        } catch is URLError {
            throw HakoError(message: "网络请求失败，登记结果尚未确认。请先刷新设备列表，确认后再重试。")
        }
        // Registration has succeeded. Keep it visible even if the follow-up GET fails;
        // presenting another submit would encourage duplicate registration.
        if let registered = try? JSONDecoder().decode(ConsoleAgentRegistrationReply.self, from: response),
           !registered.id.isEmpty, !agents.contains(where: { $0.id == registered.id }) {
            agents.append(ConsoleAgent(id: registered.id, name: registration.name, online: false, lastSeen: "", capabilities: nil))
        }
        do {
            try await fetchAgentsInternal()
            message = "Agent 已添加，公钥即时生效。请在对应设备的 Agent 中重新连接服务器。"
        } catch {
            message = "Agent 已添加，但设备列表刷新失败：\(error.localizedDescription) 请刷新列表查看最新状态。"
        }
    }

    private func fetchAgentsInternal() async throws {
        struct List: Decodable { let agents: [ConsoleAgent] }
        let agents = try JSONDecoder().decode(List.self, from: await authorized("list")).agents
        prepareContext()
        state.inventory.receive(agents)
        inventoryStorage.save(state.inventory)
    }
    func query(_ agent: ConsoleAgent) async {
        guard authenticated, !logoutPending, deviceData[agent.id]?.loading != true else { return }
        if let capabilities = agent.capabilities, !capabilities.contains(where: {
            $0.name.hasPrefix("query.") || $0.name == DeviceServiceCommand.status
        }) { return }
        let context = requestContext
        deviceData[agent.id, default: ConsoleDeviceData()].loading = true
        let liveUpdates = deviceData[agent.id]?.liveUpdates ?? [:]
        deviceData[agent.id]?.error = nil
        defer { if context == requestContext { deviceData[agent.id]?.loading = false } }
        // The guardian can answer service administration while the main process
        // is offline. Keep its result independent of the main query aggregate.
        if agent.capabilities?.contains(where: { $0.name == DeviceServiceCommand.status }) != false {
            await refreshServices(agent)
        }
        guard context == requestContext, !Task.isCancelled else { return }
        if agent.capabilities?.contains(where: { $0.name.hasPrefix("query.") }) == false { return }
        do {
            let data = try await authorized("request", agentID: agent.id,
                                            body: ["method": "query.all", "version": 1, "params": [String: Any]()])
            guard context == requestContext else { return }
            if let index = agents.firstIndex(where: { $0.id == agent.id }) {
                let old = agents[index]
                agents[index] = ConsoleAgent(id: old.id, name: old.name, online: true,
                                            lastSeen: old.lastSeen, capabilities: old.capabilities)
            }
            let reply = try JSONDecoder().decode(ConsoleAgentReply<ConsoleQueryResult>.self, from: data)
            switch reply {
            case .failure(let error): throw error
            case .result(let result):
                if var state = deviceData[agent.id] {
                    state.mergeQueries(result.data, since: liveUpdates)
                    deviceData[agent.id] = state
                }
                deviceData[agent.id]?.loaded = true
            }
        } catch is CancellationError { }
        catch { if context == requestContext { deviceData[agent.id]?.error = DeviceMonitorFailure.message(for: error) } }
    }

    func watchLive(_ agent: ConsoleAgent, onSubscribed: @MainActor () -> Void) async throws {
        struct Update: Decodable {
            let method: String
        }
        let context = requestContext
        let (socket, hello) = try await authentication.openWebSocket(AgentRequestSocket.path + "/live/" + agent.id, logSource: .devices)
        defer { socket.cancel(with: .goingAway, reason: nil) }
        try AgentSocketFrame.requireReady(hello)
        let decoder = JSONDecoder()
        try await withTaskCancellationHandler {
            var subscribed = false
            while true {
                let data = try await socket.receiveData()
                try Task.checkCancellation()
                guard context == requestContext else { throw CancellationError() }
                let frame = try decoder.decode(AgentSocketFrame.self, from: data)
                switch frame.type {
                case "subscribed":
                    subscribed = true
                    onSubscribed()
                case "update" where subscribed:
                    let update = try decoder.decode(Update.self, from: data)
                    let value = try decoder.decode(ConsoleCapabilityData.self, from: data)
                    guard (update.method.hasPrefix("query.") || update.method == DeviceServiceCommand.status), value.version > 0 else { continue }
                    var state = deviceData[agent.id] ?? ConsoleDeviceData()
                    state.entries[update.method] = value
                    state.liveUpdates[update.method] = UUID()
                    state.loaded = true
                    deviceData[agent.id] = state
                case "error":
                    _ = try frame.replyData()
                    throw CocoaError(.coderReadCorrupt)
                default:
                    throw CocoaError(.coderReadCorrupt)
                }
            }
        } onCancel: { socket.cancel(with: .goingAway, reason: nil) }
    }
    @discardableResult func refreshServices(_ agent: ConsoleAgent) async -> Bool {
        let context = requestContext
        let revision = deviceData[agent.id]?.liveUpdates[DeviceServiceCommand.status]
        do {
            let result = try await invokeAgent(agent, method: DeviceServiceCommand.status, version: 1, as: ConsoleJSON.self)
            guard context == requestContext, !Task.isCancelled else { return false }
            guard deviceData[agent.id]?.liveUpdates[DeviceServiceCommand.status] == revision else { return true }
            deviceData[agent.id, default: ConsoleDeviceData()].entries[DeviceServiceCommand.status] =
                ConsoleCapabilityData(version: 1, result: result)
            deviceData[agent.id]?.liveUpdates[DeviceServiceCommand.status] = UUID()
            deviceData[agent.id]?.loaded = true
            return true
        } catch {
            guard context == requestContext, !Task.isCancelled else { return false }
            guard deviceData[agent.id]?.liveUpdates[DeviceServiceCommand.status] == revision else { return false }
            deviceData[agent.id, default: ConsoleDeviceData()].entries[DeviceServiceCommand.status] =
                ConsoleCapabilityData(version: 1, error: ConsoleAgentError(code: "query_failed", message: error.localizedDescription))
            deviceData[agent.id]?.liveUpdates[DeviceServiceCommand.status] = UUID()
            return false
        }
    }
    func checkHTTP(_ agent: ConsoleAgent, url: String) async {
        guard authenticated, !logoutPending, httpChecks[agent.id]?.loading != true else { return }
        let context = requestContext
        httpChecks[agent.id, default: ConsoleHTTPCheckState()].loading = true
        httpChecks[agent.id]?.error = nil
        defer { if context == requestContext { httpChecks[agent.id]?.loading = false } }
        do {
            let result = try await invokeAgent(agent, method: "action.network.http.check", version: 1,
                                               params: ["url": url.trimmingCharacters(in: .whitespacesAndNewlines)], as: ConsoleHTTPCheck.self)
            guard context == requestContext else { return }
            httpChecks[agent.id]?.result = result
        } catch is CancellationError { }
        catch { if context == requestContext { httpChecks[agent.id]?.error = DeviceMonitorFailure.message(for: error) } }
    }
    func invokeAgent<Result: Decodable>(_ agent: ConsoleAgent, method: String, version: Int, params: [String: Any] = [:], as type: Result.Type) async throws -> Result {
        guard authenticated, !logoutPending else { throw HakoError(message: "请先登录 Hako 服务器。") }
        let data = try await authorized("request", agentID: agent.id, body: ["method": method, "version": version, "params": params])
        let reply = try JSONDecoder().decode(ConsoleAgentReply<Result>.self, from: data)
        switch reply {
        case .failure(let error): throw error
        case .result(let result): return result
        }
    }
}
