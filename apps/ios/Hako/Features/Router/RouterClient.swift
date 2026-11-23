import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

protocol RouterAccess: Sendable {
    func currentRoute() async -> RouterRoute?
    func read() async throws -> RouterSnapshot
    func save(_ draft: RouterBindingDraft, replacing: RouterBinding?) async throws
    func remove(_ binding: RouterBinding) async throws
    func read(_ resource: RouterResource) async throws -> RouterJSON
    func changeDevice(_ device: RouterDevice, change: RouterDeviceChange) async throws
    func apply(_ change: RouterConfigurationChange) async throws
    func wake(mac: String) async throws
    func reboot() async throws
}

actor RouterClient: RouterAccess {
    private let connection: RouterConnection
    private var route: RouterRoute?
    private let isLocal: @Sendable () async throws -> Bool
    private let session: URLSession
    private let ownsSession: Bool
    private var token: String?
    private var authentication: Task<String, Error>?

    init(connection: RouterConnection, isLocal: @escaping @Sendable () async throws -> Bool,
         session: URLSession? = nil) throws {
        self.connection = try connection.normalized()
        self.isLocal = isLocal
        self.session = session ?? HTTPTransport.makeSession(requestTimeout: 15, resourceTimeout: 25, useSystemProxy: false)
        ownsSession = session == nil
    }
    deinit { if ownsSession { session.invalidateAndCancel() } }

    func currentRoute() -> RouterRoute? { route }

    private func selectRoute() async throws {
        // The host owns network classification. The child only selects transport.
        let local = try await isLocal()
        try Task.checkCancellation()
        let next: RouterRoute = local ? .direct : .sora
        if next != route { token = nil }
        route = next
    }

    private func login() async throws -> String {
        if route == nil { try await selectRoute() }
        if let token { return token }
        if let authentication { return try await authentication.value }
        let task = Task { () throws -> String in
            let response = try await post(["method": "do", "login": ["password": RouterPassword.encode(connection.password)]], token: nil)
            guard let raw = response["stok"] as? String, let token = raw.removingPercentEncoding,
                  !token.isEmpty, token.count <= 512,
                  token.utf8.allSatisfy({ (33...126).contains($0) }) else {
                let field = response["stok"] == nil ? "缺失" : (response["stok"] as? String)?.isEmpty == true ? "为空" : "格式无效"
                HakoLog.record(.hako, .error, "路由器登录未返回有效会话",
                    detail: "响应码：0\n会话字段：\(field)\n传输：\(route?.title ?? "未选择")")
                throw RouterFailure(message: "路由器已响应，但没有返回可用登录会话。请刷新重试。")
            }
            return token
        }
        authentication = task
        defer { authentication = nil }
        let value = try await task.value
        token = value
        return value
    }

    func read() async throws -> RouterSnapshot {
        try await selectRoute()
        // Only reads may reauthenticate/retry. Mutations are sent once.
        do { return try await snapshot() }
        catch let error as RouterFailure where error.message == Self.expired {
            token = nil
            return try await snapshot()
        }
    }
    private func snapshot() async throws -> RouterSnapshot {
        let token = try await login()
        return try RouterSnapshot(await post([
            "method": "get", "hosts_info": ["table": ["online_host", "offline_host", "blocked_host"]],
            "ip_mac_bind": ["table": "user_bind"], "network": ["name": "lan"], "system": ["name": "sys_mode"]
        ], token: token))
    }

    func save(_ draft: RouterBindingDraft, replacing original: RouterBinding?) async throws {
        let current = try await read()
        guard current.routerMode else { throw RouterFailure(message: "AP 或无线中继模式下不能管理 IP/MAC 绑定。") }
        if let original, !current.bindings.contains(original) {
            throw RouterFailure(message: "此绑定已在路由器上改变，请刷新列表后重新编辑。")
        }
        let value = try draft.validated(in: current, replacing: original?.id)
        let fields = ["ip": value.ip, "mac": value.mac, "hostname": value.name]
        let body: [String: Any]
        if let original {
            body = ["method": "set", "ip_mac_bind": [original.id: fields]]
        } else {
            body = ["method": "add", "ip_mac_bind": ["table": "user_bind", "name": current.nextBindingName, "para": fields]]
        }
        _ = try await post(body, token: try await login(), mutation: true)
    }

    func remove(_ binding: RouterBinding) async throws {
        let current = try await read()
        guard current.routerMode else { throw RouterFailure(message: "AP 或无线中继模式下不能管理 IP/MAC 绑定。") }
        guard current.bindings.contains(binding), RouterSnapshot.validSection(binding.id) else {
            throw RouterFailure(message: "此绑定已在路由器上改变，请刷新列表后重新操作。")
        }
        _ = try await post(["method": "delete", "ip_mac_bind": ["name": [binding.id]]], token: try await login(), mutation: true)
    }

    func read(_ resource: RouterResource) async throws -> RouterJSON {
        try await selectRoute()
        var body = resource.query; body["method"] = resource.method
        do { return try await resourceData(resource, body: body) }
        catch let error as RouterFailure where error.message == Self.expired {
            token = nil
            return try await resourceData(resource, body: body)
        }
    }
    private func resourceData(_ resource: RouterResource, body: [String: Any]) async throws -> RouterJSON {
        let data = try RouterJSON(await post(body, token: try await login()))
        try resource.validate(data)
        return data
    }

    func changeDevice(_ device: RouterDevice, change: RouterDeviceChange) async throws {
        let snapshot = try await read()
        guard let current = snapshot.devices.first(where: { $0.mac == device.mac }),
              current.name == device.name, current.blocked == device.blocked,
              current.uploadLimit == device.uploadLimit, current.downloadLimit == device.downloadLimit else {
            throw RouterFailure(message: "设备设置已改变，请刷新详情后重新操作。")
        }
        if case .limit = change {
            let capabilities = try await read(.capabilities)["function"]["new_module_spec"]
            if capabilities["hnat"].enabled {
                let acceleration = try await post(["method": "get", "hnat": ["name": "main"]], token: try await login())
                if try RouterJSON(acceleration)["hnat"]["main"]["enable"].enabled {
                    throw RouterFailure(message: "当前已开启硬件加速，请在路由器中核对加速与限速设置后重试。")
                }
            }
        }
        let (action, fields) = try change.fields(for: current)
        _ = try await post(["method": "do", "hosts_info": [action: fields]], token: try await login(), mutation: true)
    }

    func apply(_ change: RouterConfigurationChange) async throws {
        let snapshot = try await read()
        let current = try await read(change.resource)
        let payload = try change.payload(current: current, snapshot: snapshot)
        _ = try await post(payload, token: try await login(), mutation: true)
    }

    func wake(mac: String) async throws {
        let value = try RouterAddress.mac(mac)
        _ = try await read()
        _ = try await post(["method": "do", "wake_on_lan": ["wake_device": [["key": ["mac": value]]]]], token: try await login(), mutation: true)
    }
    func reboot() async throws {
        _ = try await read()
        _ = try await post(["method": "do", "system": ["reboot": NSNull()]], token: try await login(), mutation: true)
        token = nil
    }

    private static let expired = "路由器会话已过期，请刷新后重新操作。"
    private func post(_ body: [String: Any], token: String?, mutation: Bool = false) async throws -> [String: Any] {
        let escapedToken = token.map(Self.escapeComponent) ?? ""
        let path = token.map { _ in "/stok=\(escapedToken)/ds" } ?? "/"
        guard let url = URL(string: "http://\(connection.address)\(path)") else { throw RouterFailure.incompatible }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("http://\(connection.address)/", forHTTPHeaderField: "Referer")
        if route == .sora { request.setValue("\(connection.address):80", forHTTPHeaderField: "X-Proxy") }
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.encodeStrings(body))
        let data: Data, response: URLResponse
        do {
            (data, response) = try await HTTPTransport.data(for: request, using: session,
                secrets: [connection.password, RouterPassword.encode(connection.password), token ?? "", escapedToken], logBody: false)
        } catch {
            if mutation { throw RouterFailure(message: "请求已发送但未确认结果，请刷新核对路由器状态，勿重复提交。", outcomeUnknown: true) }
            if route == .sora {
                let detail = HTTPLogRedactor(request: request, secrets: [connection.password,
                    RouterPassword.encode(connection.password), token ?? "", escapedToken]).text(error.localizedDescription)
                throw RouterFailure(message: "Sora 代理连接失败：\(detail)\n请确认已登录 Sora，并在主应用“设置 → HTTP 代理”选择可访问路由器的在线 Agent。")
            }
            throw RouterFailure(message: "无法连接路由器，请确认已接入同一局域网，并允许 Hako 访问本地网络。")
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 4 * 1024 * 1024,
              let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = result["error_code"] as? Int else {
            throw RouterFailure(message: "路由器响应异常，请刷新核对当前状态。", outcomeUnknown: mutation)
        }
        guard code == 0 else {
            if code == -40401, token != nil { self.token = nil; throw RouterFailure(message: Self.expired) }
            if token == nil {
                throw RouterFailure(message: "管理员登录失败（\(code)），请检查密码；若已锁定，请稍后再试。")
            }
            throw RouterFailure(message: "路由器拒绝请求（\(code)），请刷新核对固件支持情况。")
        }
        return result
    }

    private static func encodeStrings(_ value: Any) -> Any {
        // The firmware's JSON.stringify replacer applies encodeURIComponent to every string value.
        if let text = value as? String {
            return escapeComponent(text)
        }
        if let array = value as? [Any] { return array.map(encodeStrings) }
        if let object = value as? [String: Any] { return object.mapValues(encodeStrings) }
        return value
    }
    private static func escapeComponent(_ text: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}
