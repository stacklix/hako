import Foundation
import Combine

@MainActor final class DeviceMonitorClient: ObservableObject {
    static let shared = DeviceMonitorClient()
    private let authentication: any AuthenticatedServerAccess
    private let socket: DeviceMonitorSocket
    private var subscription: AnyCancellable?
    private struct State {
        var context = ""
        var agents: [ConsoleAgent] = []
        var deviceData: [String: ConsoleDeviceData] = [:]
        var httpChecks: [String: ConsoleHTTPCheckState] = [:]
        var message: String?
    }
    @Published private var state = State()
    @Published private var working = false
    init(authentication: (any AuthenticatedServerAccess)? = nil) {
        let authentication = authentication ?? AuthenticatedServerService.shared
        self.authentication = authentication
        self.socket = DeviceMonitorSocket(authentication: authentication)
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
    private var current: State { state.context == requestContext ? state : State(context: requestContext) }
    private func prepareContext() { if state.context != requestContext { state = State(context: requestContext) } }
    var agents: [ConsoleAgent] {
        get { current.agents }
        set { prepareContext(); state.agents = newValue }
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
        get { current.message ?? authentication.message }
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
            case "agent_offline": text = "设备当前离线。"
            case "agent_disconnected": text = "设备连接已中断，请重试。"
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
            throw error
        }
    }
    private func execute(_ action: () async throws -> Void) async {
        guard !busy else { return }
        working = true; message = nil
        defer { working = false }
        do { try await action() }
        catch is CancellationError { }
        catch { message = error.localizedDescription }
    }
    func fetchAgents() async { await execute { try await self.fetchAgentsInternal() } }

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
        agents = try JSONDecoder().decode(List.self, from: await authorized("list")).agents
    }
    func query(_ agent: ConsoleAgent) async {
        guard authenticated, !logoutPending, deviceData[agent.id]?.loading != true else { return }
        if let capabilities = agent.capabilities, !capabilities.contains(where: { $0.name.hasPrefix("query.") }) { return }
        let context = requestContext
        deviceData[agent.id, default: ConsoleDeviceData()].loading = true
        let liveUpdates = deviceData[agent.id]?.liveUpdates ?? [:]
        deviceData[agent.id]?.error = nil
        defer { if context == requestContext { deviceData[agent.id]?.loading = false } }
        do {
            let data = try await authorized("request", agentID: agent.id,
                                            body: ["method": "query.all", "version": 1, "params": [String: Any]()])
            let manifest = try JSONDecoder().decode(ConsoleQueryEnvelope.self, from: data)
            guard context == requestContext else { return }
            if let index = agents.firstIndex(where: { $0.id == agent.id }) {
                let old = agents[index]
                agents[index] = ConsoleAgent(id: old.id, name: old.name, online: true,
                                            lastSeen: old.lastSeen, capabilities: manifest.capabilities)
            }
            let reply = try JSONDecoder().decode(ConsoleAgentReply<ConsoleQueryResult>.self, from: data)
            switch reply {
            case .failure(let error): throw error
            case .result(let result):
                if var state = deviceData[agent.id] {
                    state.entries = result.data.merging(state.entries.filter {
                        state.liveUpdates[$0.key] != liveUpdates[$0.key]
                    }) { _, live in live }
                    deviceData[agent.id] = state
                }
                deviceData[agent.id]?.loaded = true
            }
        } catch is CancellationError { }
        catch { if context == requestContext { deviceData[agent.id]?.error = error.localizedDescription } }
    }

    func watchLive(_ agent: ConsoleAgent, onSubscribed: @MainActor () -> Void) async throws {
        struct Update: Decodable {
            let method: String
        }
        let context = requestContext
        let (socket, hello) = try await authentication.openWebSocket(DeviceMonitorSocket.path + "/live/" + agent.id, logSource: .devices)
        defer { socket.cancel(with: .goingAway, reason: nil) }
        try DeviceMonitorFrame.requireReady(hello)
        let decoder = JSONDecoder()
        try await withTaskCancellationHandler {
            var subscribed = false
            while true {
                let data = try await socket.receiveData()
                try Task.checkCancellation()
                guard context == requestContext else { throw CancellationError() }
                let frame = try decoder.decode(DeviceMonitorFrame.self, from: data)
                switch frame.type {
                case "subscribed":
                    subscribed = true
                    onSubscribed()
                case "update" where subscribed:
                    let update = try decoder.decode(Update.self, from: data)
                    let value = try decoder.decode(ConsoleCapabilityData.self, from: data)
                    guard update.method.hasPrefix("query."), value.version > 0 else { continue }
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
        catch { if context == requestContext { httpChecks[agent.id]?.error = error.localizedDescription } }
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
