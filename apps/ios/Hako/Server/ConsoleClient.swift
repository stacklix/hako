import Foundation
import Combine

struct ConsoleTokens: Codable {
    let sessionId: String
    let deviceId: String
    let accessToken: String
    let refreshToken: String
    let expiresAt: String
}
struct ConsoleSession: Codable {
    var tokens: ConsoleTokens
    var rotationId: String?
    var logoutPending = false
}

struct ConsoleRemoteSession: Decodable, Identifiable {
    enum Kind: String, Decodable { case console, web, application }
    let id: String
    let type: Kind
    let deviceId: String?
    let browser: String?
    var application: String? = nil
    var origin: String? = nil
    let createdAt: String
    let lastUsedAt: String?
    let current: Bool
}

@MainActor final class ConsoleClient: ObservableObject, AuthenticatedServerAccess {
    static let shared = ConsoleClient()
    @Published var serverURL = UserDefaults.standard.string(forKey: "console.serverURL") ?? ""
    @Published private(set) var authenticated = false
    @Published private(set) var hasSavedSession = false
    @Published private(set) var logoutPending = false
    @Published var username = UserDefaults.standard.string(forKey: "console.username") ?? ""
    @Published private(set) var deviceId = ""
    @Published private(set) var publicKeyPEM = ""
    @Published private(set) var remoteSessions: [ConsoleRemoteSession] = []
    @Published private(set) var busy = false
    @Published private(set) var resettingKey = false
    @Published var message: String?
    private var saved: ConsoleSession?
    private let restoration = ConsoleSessionRestoration()
    private var refreshTask: Task<Void, Error>?
    private var refreshTaskID: UUID?
    private let transport: URLSession

    private init() {
        transport = HTTPTransport.makeSession()
    }

    var changes: AnyPublisher<Void, Never> { objectWillChange.eraseToAnyPublisher() }
    func send(_ path: String, method: String, body: [String: Any]?, logSource: HakoLogSource) async throws -> Data {
        let context = requestContext
        do {
            let data = try await authorized(path, method: method, body: body, logSource: logSource)
            guard context == requestContext else { throw CancellationError() }
            return data
        } catch {
            guard context == requestContext else { throw CancellationError() }
            throw error
        }
    }

    var requestContext: String { serverURL + "\n" + username + "\n" + (saved?.tokens.sessionId ?? "") + "|\(authenticated)|\(logoutPending)" }

    private var sessionAccount: String { "session." + (serverURL + "\n" + username).consoleDigest }
    private func identity() throws -> ConsoleIdentity { try ConsoleIdentity.load(origin: serverURL.isEmpty ? nil : serverURL) }
    // This is a local operation: no configuration validation, session check or HTTP request.
    func publicKeyForExport() throws -> String {
        guard !resettingKey else { throw HakoError(message: "正在重置密钥对，请稍后导出。") }
        let device = try identity()
        let pem = try device.publicKeyPEM()
        deviceId = device.deviceId; publicKeyPEM = pem
        return pem
    }
    func resetKeyPair() async {
        await execute {
            self.resettingKey = true
            defer { self.resettingKey = false }
            if let task = self.refreshTask {
                task.cancel()
                _ = try? await task.value
                self.refreshTask = nil; self.refreshTaskID = nil
            }
            var pem = ""
            let device = try ConsoleIdentity.reset(prepare: { pem = try $0.publicKeyPEM() })
            self.saved = nil; self.authenticated = false; self.hasSavedSession = false; self.logoutPending = false
            self.remoteSessions = []
            self.deviceId = device.deviceId; self.publicKeyPEM = pem
            do {
                try ConsoleKeychain.clearRetiredIdentityEntries()
                self.message = "密钥对已重置，已退出本机登录。请导出新公钥，替换服务端旧公钥并重启服务后重新登录。"
            } catch {
                self.message = "密钥对已重置，旧身份已停用，但旧凭据清理失败：\(error.localizedDescription) 请导出新公钥并更新服务端配置。"
            }
        }
    }
    private func persist(_ value: ConsoleSession?) throws {
        if let value { try ConsoleKeychain.save(sessionAccount, data: JSONEncoder().encode(value)) }
        else { try ConsoleKeychain.delete(sessionAccount) }
        saved = value
        logoutPending = value?.logoutPending ?? false
        hasSavedSession = value != nil && !logoutPending
    }

    func saveServer(_ text: String, username: String) throws {
        guard !busy else { throw HakoError(message: "正在处理其他请求，请稍后重试。") }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed), components.scheme == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            throw HakoError(message: "请输入 HTTPS 服务器根地址，例如 https://hako.example.com。")
        }
        var normalized = components
        normalized.host = host.lowercased(); normalized.path = ""
        guard let origin = normalized.url?.absoluteString else { throw HakoError(message: "服务器地址无效。") }
        let account = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard account.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil else { throw HakoError(message: "账号应为 1–80 位英文字母、数字、下划线或连字符。") }
        guard origin != serverURL || account != self.username else { return }
        self.username = account
        UserDefaults.standard.set(account, forKey: "console.username")
        self.serverURL = origin
        UserDefaults.standard.set(origin, forKey: "console.serverURL")
        self.saved = nil; self.authenticated = false; self.hasSavedSession = false; self.logoutPending = false
        self.remoteSessions = []
        self.deviceId = ""; self.publicKeyPEM = ""
        message = "服务器配置已保存。"
    }

    func restore() async {
        await restoration.run {
            await self.execute { try await self.restoreInternal() }
        }
    }
    private func restoreInternal() async throws {
        _ = try publicKeyForExport()
        guard !serverURL.isEmpty else { return }
        if let data = try ConsoleKeychain.read(sessionAccount) {
            let restored = try JSONDecoder().decode(ConsoleSession.self, from: data)
            guard restored.tokens.deviceId == deviceId else {
                try persist(nil); authenticated = false; remoteSessions = []
                return
            }
            saved = restored
        }
        logoutPending = saved?.logoutPending ?? false
        hasSavedSession = saved != nil && !logoutPending
        if logoutPending { try await finishLogout(); return }
        if saved != nil {
            _ = try await authorized("/api/v1/auth/session")
            authenticated = true
        }
    }

    func login() async {
        await execute {
            let device = try self.identity()
            let data = try await self.request("/api/v1/auth/challenge", method: "POST", body: ["username": self.username, "deviceId": device.deviceId], token: nil)
            struct Challenge: Decodable { let challengeId: String; let nonce: String }
            let challenge = try JSONDecoder().decode(Challenge.self, from: data)
            let result = try await self.request("/api/v1/auth/login", method: "POST", body: ["username": self.username, "deviceId": device.deviceId, "challengeId": challenge.challengeId], token: nil, nonce: challenge.nonce)
            try self.acceptTokens(result)
            self.authenticated = true
        }
    }
    private func acceptTokens(_ data: Data) throws {
        let tokens = try JSONDecoder().decode(ConsoleTokens.self, from: data)
        guard tokens.deviceId == (try identity()).deviceId else { throw HakoError(message: "服务器返回的设备身份不匹配。") }
        try persist(ConsoleSession(tokens: tokens))
    }

    private func request(_ path: String, method: String, body: [String: Any]?, token: String?, signed: Bool = true, nonce: String? = nil, logSource: HakoLogSource = .hako) async throws -> Data {
        guard let url = URL(string: serverURL + path), url.scheme == "https" else { throw HakoError(message: "请先在 Hako 设置的“服务器与登录”中配置 HTTPS 服务器。") }
        let started = Date.now
        var outcome = "连接或请求准备失败"
        var logLevel = HakoLogLevel.error
        defer {
            HakoLog.record(logSource, logLevel, "Hako 服务 · \(method)",
                detail: "\(HakoLog.safeURL(url.absoluteString))\n\(outcome)\n耗时：\(Int(Date.now.timeIntervalSince(started) * 1000)) ms",
                secrets: [token ?? "", nonce ?? ""])
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = method
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if signed {
            let device = try identity()
            request.setValue(try device.proof(method: method, url: url, accessToken: token, nonce: nonce), forHTTPHeaderField: "DPoP")
            request.setValue(device.deviceId, forHTTPHeaderField: "X-Hako-Device")
        }
        if let token { request.setValue("DPoP " + token, forHTTPHeaderField: "Authorization") }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch {
            // URLSession uses URLError.cancelled for task cancellation; callers
            // already handle CancellationError silently and retain credentials.
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                outcome = "请求已取消"; logLevel = .info
                throw CancellationError()
            }
            throw error
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw HakoError(message: "服务器响应无效。") }
        outcome = "HTTP \(http.statusCode)"
        guard (200..<300).contains(http.statusCode) else {
            struct Failure: Decodable { let error: String }
            throw ServerHTTPError(status: http.statusCode, code: (try? JSONDecoder().decode(Failure.self, from: data).error) ?? "invalid_response")
        }
        logLevel = .info
        return data
    }

    func authorized(_ path: String, method: String = "GET", body: [String: Any]? = nil, nonce: String? = nil, logSource: HakoLogSource = .hako) async throws -> Data {
        guard !resettingKey else { throw HakoError(message: "正在重置设备身份，请稍后重试。") }
        guard !logoutPending || path == "/api/v1/auth/logout" else { throw HakoError(message: "本机已退出，正在等待撤销服务端会话。") }
        guard let session = saved else { throw HakoError(message: "请先登录。") }
        let context = requestContext
        do { return try await request(path, method: method, body: body, token: session.tokens.accessToken, nonce: nonce, logSource: logSource) }
        catch let error as ServerHTTPError where error.status == 401 {
            guard context == requestContext else { throw CancellationError() }
            try await refresh()
            guard context == requestContext else { throw CancellationError() }
            guard let renewed = saved else { throw error }
            return try await request(path, method: method, body: body, token: renewed.tokens.accessToken, nonce: nonce, logSource: logSource)
        }
    }
    private func refresh() async throws {
        guard !resettingKey else { throw HakoError(message: "正在重置设备身份，请稍后重试。") }
        if let task = refreshTask { return try await task.value }
        let taskID = UUID()
        let context = requestContext
        let task = Task { @MainActor in
            guard var session = self.saved else { throw HakoError(message: "请重新登录。") }
            if session.rotationId == nil { session.rotationId = UUID().uuidString.lowercased(); try self.persist(session) }
            do {
                let data = try await self.request("/api/v1/auth/refresh", method: "POST", body: ["sessionId": session.tokens.sessionId,
                    "deviceId": session.tokens.deviceId, "refreshToken": session.tokens.refreshToken, "rotationId": session.rotationId!], token: nil)
                let tokens = try JSONDecoder().decode(ConsoleTokens.self, from: data)
                guard context == self.requestContext else { throw CancellationError() }
                guard tokens.deviceId == session.tokens.deviceId else { throw HakoError(message: "设备绑定不匹配。") }
                try self.persist(ConsoleSession(tokens: tokens, logoutPending: session.logoutPending))
            } catch let error as ServerHTTPError where error.code == "session_revoked" {
                guard context == self.requestContext else { throw CancellationError() }
                try self.persist(nil); self.authenticated = false
                throw error
            }
        }
        refreshTask = task
        refreshTaskID = taskID
        defer {
            if refreshTaskID == taskID { refreshTask = nil; refreshTaskID = nil }
        }
        try await task.value
    }

    func inspectWebLogin(_ payload: String) async throws -> ConsoleWebLoginRequest {
        guard authenticated, !logoutPending else { throw HakoError(message: "请先验证 Hako 服务器登录。") }
        let origin = serverURL
        let parsed = try ConsoleWebLoginPayload(payload.trimmingCharacters(in: .whitespacesAndNewlines), origin: origin)
        let data = try await authorized("/api/v1/auth/web-login/requests/\(parsed.requestId)")
        let result = try JSONDecoder().decode(ConsoleWebLoginRequest.self, from: data)
        guard serverURL == origin else { throw ConsoleWebLoginError.serverMismatch }
        try result.validate(origin: origin, requestId: parsed.requestId, applicationRequest: parsed.isApplication, oidcRequest: parsed.isOIDC)
        return result
    }

    func confirmWebLogin(_ login: ConsoleWebLoginRequest, approve: Bool) async throws {
        guard authenticated, !logoutPending else { throw HakoError(message: "请先验证 Hako 服务器登录。") }
        let origin = serverURL
        try login.validate(origin: origin, requestId: login.id)
        guard serverURL == origin, authenticated, !logoutPending else { throw ConsoleWebLoginError.serverMismatch }
        try login.validate(origin: origin, requestId: login.id)
        _ = try await authorized("/api/v1/auth/web-login/requests/\(login.id)/\(approve ? "approve" : "deny")",
                                 method: "POST", body: ["confirmationCode": login.confirmationCode], nonce: login.nonce)
    }
    func fetchSessions() async {
        await execute {
            struct List: Decodable { let sessions: [ConsoleRemoteSession] }
            self.remoteSessions = try JSONDecoder().decode(List.self, from: await self.authorized("/api/v1/sessions")).sessions
        }
    }
    func revokeWebSession(_ session: ConsoleRemoteSession) async {
        guard session.type != .console else { return }
        await execute {
            _ = try await self.authorized("/api/v1/web-sessions/" + session.id, method: "DELETE")
            self.remoteSessions.removeAll { $0.id == session.id }
            self.message = "已移除网页登录，该浏览器需要重新扫码登录。"
        }
    }

    func logout() async {
        await execute {
            guard var session = self.saved else { return }
            session.logoutPending = true
            try self.persist(session)
            self.authenticated = false; self.remoteSessions = []
            try await self.finishLogout()
        }
    }
    private func finishLogout() async throws {
        do { _ = try await authorized("/api/v1/auth/logout", method: "POST") }
        catch let error as ServerHTTPError where error.code == "session_revoked" { /* already invalid */ }
        try persist(nil); authenticated = false
        message = "已退出登录，服务端会话已撤销。"
    }

    private func execute(_ action: () async throws -> Void) async {
        guard !busy else { return }
        busy = true; message = nil
        defer { busy = false }
        do { try await action() }
        catch is CancellationError { }
        catch { message = error.localizedDescription }
    }
}
