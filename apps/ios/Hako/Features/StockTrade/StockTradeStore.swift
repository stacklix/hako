import Foundation
import Combine
import CryptoKit

extension StockTradeLoginStart {
    var hakoRequest: NativeApplicationLoginRequest {
        .init(id: requestId, issuer: issuer, clientId: clientId, applicationOrigin: applicationOrigin, nonce: nonce, expiresAt: expiresAt)
    }
}

@MainActor final class StockTradeStore: ObservableObject {
    static let shared = StockTradeStore()
    @Published private(set) var connection: StockTradeConnection
    @Published private(set) var session: StockTradeSession?
    @Published private(set) var run: StockTradeRun?
    @Published private(set) var rows: [StockTradeRecord] = []
    @Published private(set) var nextCursor: String?
    @Published private(set) var pool: StockTradePool = .recommendations
    @Published private(set) var loading = false
    @Published private(set) var authenticating = false
    @Published private(set) var error: String?
    @Published private(set) var updatedAt: Date?
    @Published private(set) var favorites: [StockTradeRecord] = []
    @Published private(set) var consent: NativeApplicationConsent?
    @Published private(set) var workflowTasks: [StockTradeWorkflowTask] = []
    @Published private(set) var workflowCursor: String?
    @Published private(set) var workflowOnline = false
    @Published private(set) var workflowError: String?
    @Published private(set) var displayedRunID: String?
    @Published private(set) var missingSnapshot = false
    private var workflowsLoading = false
    private var resultGeneration = UUID()
    var activeWorkflow: StockTradeWorkflowTask? { workflowTasks.first { $0.state.active } }
    private let defaults: UserDefaults
    private let secrets: any SecretStorage
    private let authentication: any AuthenticatedServerAccess
    private let authorization: NativeApplicationAuthorization
    private let clientFactory: (StockTradeConnection) throws -> any StockTradeAccess
    private var client: (any StockTradeAccess)?
    private var context: String
    private var epoch = UUID()
    private var pending: (StockTradeLoginStart, NativeApplicationLoginProof, UUID, String)?
    private var renewalTask: Task<StockTradeSession, Error>?
    private var observer: AnyCancellable?
    private var explicitlyLoggedOut = false
    private var configurationError: String?
    private static let settingsKey = "stocktrade.connection.v1"

    init(defaults: UserDefaults = .standard,
         secrets: any SecretStorage = SecureStorage.namespace("me.stackli.hako.stocktrade.session"),
         authentication: (any AuthenticatedServerAccess)? = nil,
         clientFactory: @escaping (StockTradeConnection) throws -> any StockTradeAccess = { try StockTradeClient(connection: $0) }) {
        let authentication = authentication ?? AuthenticatedServerService.shared
        self.defaults = defaults; self.secrets = secrets; self.authentication = authentication
        self.authorization = NativeApplicationAuthorization(authentication: authentication)
        self.clientFactory = clientFactory
        context = Self.identityContext(authentication)
        if let data = defaults.data(forKey: Self.settingsKey) {
            do { connection = try JSONDecoder().decode(StockTradeConnection.self, from: data).normalized() }
            catch { connection = .init(); configurationError = "Cerno 连接配置无法读取，请重新保存。" }
        } else { connection = .init() }
        observer = authentication.changes.sink { [weak self] _ in
            Task { @MainActor in self?.synchronizeContext() }
        }
    }

    var configured: Bool { (try? connection.normalized()) != nil }
    var scope: UUID { epoch }
    var activationKey: String { connection.origin + "|" + connection.clientID + "|" + context }
    var preferenceKey: String? { favoriteKey.map { $0 + ".notifications" } }
    var accountName: String { session?.user.username ?? "尚未连接" }
    private var sessionKey: String { "session.v2." + Self.digest(connection.origin + "\n" + connection.clientID + "\n" + context) }
    private var favoriteKey: String? { session.map { "stocktrade.watchlist." + Self.digest(connection.origin + "\n" + $0.user.issuer + "\n" + $0.user.subject) } }
    private static func digest(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }

    private func clearVisible() {
        renewalTask?.cancel(); renewalTask = nil
        epoch = UUID(); pending = nil; consent = nil; session = nil; run = nil
        rows = []; nextCursor = nil; favorites = []; updatedAt = nil; loading = false; authenticating = false; error = nil
        workflowTasks = []; workflowCursor = nil; workflowOnline = false; workflowError = nil; workflowsLoading = false; displayedRunID = nil; resultGeneration = UUID(); missingSnapshot = false
    }
    private static func identityContext(_ authentication: any AuthenticatedServerAccess) -> String {
        NativeApplicationAuthorization.origin(authentication.serverURL) ?? authentication.serverURL
    }
    func synchronizeContext() {
        let current = Self.identityContext(authentication)
        if context != current {
            clearVisible(); context = current; explicitlyLoggedOut = false
        } else if let pending, pending.3 != authentication.requestContext {
            dismissConsent()
        }
    }
    private func deviceFingerprint() throws -> String {
        let key = "device.identity.v1"
        let identity: String
        if let data = try secrets.read(account: key) {
            guard let value = String(data: data, encoding: .utf8), UUID(uuidString: value) != nil else { throw StockTradeFailure.invalidResponse }
            identity = value
        } else {
            identity = UUID().uuidString.lowercased()
            try secrets.save(Data(identity.utf8), account: key, accessibility: .whenUnlocked)
        }
        return Self.digest("cerno-device-v1\n" + identity + "\n" + connection.origin + "\n" + connection.clientID)
    }
    func configure(_ value: StockTradeConnection) throws {
        let normalized = try value.normalized()
        let data = try JSONEncoder().encode(normalized)
        if normalized != connection {
            clearVisible(); client = nil; explicitlyLoggedOut = false
        }
        defaults.set(data, forKey: Self.settingsKey); connection = normalized; configurationError = nil
    }
    func dismissConsent() { pending = nil; consent = nil; authenticating = false }

    private func checked(_ ticket: UUID) throws {
        try Task.checkCancellation()
        guard ticket == epoch, context == Self.identityContext(authentication) else { throw CancellationError() }
    }
    private func checkedLogin(_ ticket: UUID, consoleContext: String) throws {
        try checked(ticket)
        guard authentication.requestContext == consoleContext, authentication.authenticated,
              !authentication.logoutPending else { throw CancellationError() }
    }
    private func renewed(_ stored: StockTradeSession, ticket: UUID) async throws -> StockTradeSession {
        if let renewalTask { return try await renewalTask.value }
        guard stored.renewable else { throw StockTradeFailure.sessionRequired }
        let task = Task { @MainActor [self] in
            let fingerprint = try deviceFingerprint()
            let value: StockTradeSession = try await raw(["auth", "native", "refresh"], method: "POST",
                body: ["deviceId": stored.deviceId, "deviceToken": stored.deviceToken, "deviceFingerprint": fingerprint], as: StockTradeSession.self)
            try checked(ticket)
            guard value.valid, value.deviceId == stored.deviceId, value.deviceToken == stored.deviceToken,
                  value.user.id == stored.user.id, value.user.issuer == stored.user.issuer, value.user.subject == stored.user.subject,
                  let expiry = StockTradeTime.date(value.expiresAt), expiry.timeIntervalSinceNow <= 12 * 3600 + 5 else { throw StockTradeFailure.invalidResponse }
            try secrets.save(try JSONEncoder().encode(value), account: sessionKey, accessibility: .whenUnlocked)
            session = value
            return value
        }
        renewalTask = task
        defer { if ticket == epoch { renewalTask = nil } }
        return try await task.value
    }
    private func forgetRevokedSession() throws {
        let key = sessionKey
        clearVisible(); explicitlyLoggedOut = true
        error = StockTradeFailure.sessionRequired.localizedDescription
        try secrets.delete(account: key)
    }
    private func backend() throws -> any StockTradeAccess {
        if let client { return client }
        let value = try clientFactory(connection); client = value; return value
    }
    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw StockTradeFailure.invalidResponse }
    }
    private func raw<T: Decodable>(_ path: [String], query: [URLQueryItem] = [], method: String = "GET",
                                   body: [String: String]? = nil, token: String? = nil, as: T.Type) async throws -> T {
        let data = try await backend().data(path, query: query, method: method,
            body: try body.map { try JSONEncoder().encode($0) }, token: token)
        return try decode(T.self, data)
    }
    func read<T: Decodable>(_ path: [String], query: [URLQueryItem] = [], method: String = "GET", body: [String: String]? = nil, as: T.Type) async throws -> T {
        synchronizeContext()
        let ticket = epoch
        guard var current = session else { throw StockTradeFailure.sessionRequired }
        var didRenew = false
        do {
            if !current.valid || StockTradeTime.date(current.expiresAt).map({ $0.timeIntervalSinceNow < 120 }) == true {
                didRenew = true; current = try await renewed(current, ticket: ticket)
            }
            do {
                let value: T = try await raw(path, query: query, method: method, body: body, token: current.accessToken, as: T.self)
                try checked(ticket)
                return value
            } catch let failure as StockTradeFailure where failure.invalidatesSession && !didRenew {
                current = try await renewed(current, ticket: ticket)
                let value: T = try await raw(path, query: query, method: method, body: body, token: current.accessToken, as: T.self)
                try checked(ticket)
                return value
            }
        } catch {
            guard ticket == epoch else { throw CancellationError() }
            let failure = StockTradeClient.transportFailure(error)
            if (failure as? StockTradeFailure)?.invalidatesSession == true { try forgetRevokedSession(); throw StockTradeFailure.sessionRequired }
            throw failure
        }
    }

    func activate(force: Bool = false) async {
        synchronizeContext()
        guard configured else { error = configurationError; return }
        guard !explicitlyLoggedOut, !authenticating, !loading, consent == nil, pending == nil else { return }
        if session == nil || session?.valid == false { await login(); return }
        if force || updatedAt.map({ Date.now.timeIntervalSince($0) >= 60 }) != false { await refresh() }
    }

    func login() async {
        synchronizeContext()
        guard !authenticating else { return }
        authenticating = true; error = nil; explicitlyLoggedOut = false
        let ticket = epoch
        defer { if ticket == epoch { authenticating = false } }
        do {
            _ = try connection.normalized()
            var stored = session
            if stored == nil, let data = try secrets.read(account: sessionKey) { stored = try decode(StockTradeSession.self, data) }
            if let stored {
                session = stored
                do {
                    struct Identity: Decodable { let user: StockTradeUser }
                    let verified: Identity = try await read(["auth", "session"], as: Identity.self)
                    try checked(ticket)
                    guard let current = session, verified.user.id == current.user.id, verified.user.issuer == current.user.issuer,
                          verified.user.subject == current.user.subject,
                          NativeApplicationAuthorization.origin(verified.user.issuer) == context else { throw StockTradeFailure.invalidResponse }
                    session = current
                    loadFavorites(); await refresh(); return
                } catch let failure as StockTradeFailure where failure.invalidatesSession {
                    try forgetRevokedSession()
                    throw StockTradeFailure.sessionRequired
                }
            }
            guard authentication.authenticated, !authentication.logoutPending else { throw NativeApplicationAuthorizationError.loginRequired }
            let consoleContext = authentication.requestContext
            let meta: StockTradeMeta = try await raw(["meta"], as: StockTradeMeta.self)
            try checkedLogin(ticket, consoleContext: consoleContext)
            guard meta.auth.configured else { throw StockTradeFailure.api(status: 503, code: "auth_not_configured", requestID: "", retryable: false) }
            guard meta.apiVersion == "1", meta.timezone == "Asia/Shanghai", meta.auth.refreshSupported,
                  meta.auth.deviceBoundRefresh, meta.auth.sessionAuthority == "cerno", meta.auth.clientId == connection.clientID,
                  let backendOrigin = connection.applicationOrigin,
                  NativeApplicationAuthorization.origin(meta.auth.applicationOrigin) == backendOrigin,
                  let issuer = NativeApplicationAuthorization.origin(authentication.serverURL),
                  NativeApplicationAuthorization.origin(meta.auth.issuer) == issuer else { throw NativeApplicationAuthorizationError.bindingMismatch }
            let proof = try NativeApplicationLoginProof()
            let start: StockTradeLoginStart = try await raw(["auth", "native", "start"], method: "POST",
                body: ["codeChallenge": proof.challenge, "codeChallengeMethod": "S256", "deviceFingerprint": try deviceFingerprint()], as: StockTradeLoginStart.self)
            try checkedLogin(ticket, consoleContext: consoleContext)
            guard !start.loginId.isEmpty, start.codeChallenge == proof.challenge, start.codeChallengeMethod == "S256" else { throw StockTradeFailure.invalidResponse }
            do {
                let code = try await authorization.authorize(start.hakoRequest, proof: proof,
                    expectedClientID: connection.clientID, backendOrigin: backendOrigin)
                try await complete(start, proof: proof, code: code, ticket: ticket, consoleContext: consoleContext)
            } catch NativeApplicationAuthorizationError.consentRequired(let value) {
                try checkedLogin(ticket, consoleContext: consoleContext); pending = (start, proof, ticket, consoleContext); consent = value
            }
        } catch is CancellationError { }
        catch { if ticket == epoch { self.error = error.localizedDescription } }
    }

    func confirmConsent() async throws {
        guard let pending, let consent else { throw StockTradeFailure.changedContext }
        let (start, proof, ticket, consoleContext) = pending
        // Retire the pending context before exchange: a failed/uncertain complete is never replayed.
        self.pending = nil
        authenticating = true
        defer { if ticket == epoch { authenticating = false } }
        do {
            try checkedLogin(ticket, consoleContext: consoleContext)
            let code = try await authorization.confirm(consent)
            try await complete(start, proof: proof, code: code, ticket: ticket, consoleContext: consoleContext)
        } catch {
            if ticket == epoch { self.error = error.localizedDescription; self.consent = nil }
            throw error
        }
    }
    private func complete(_ start: StockTradeLoginStart, proof: NativeApplicationLoginProof,
                          code: NativeApplicationAuthorizationCode, ticket: UUID, consoleContext: String) async throws {
        try checkedLogin(ticket, consoleContext: consoleContext)
        let value: StockTradeSession = try await raw(["auth", "native", "complete"], method: "POST",
            body: ["loginId": start.loginId, "code": code.code, "codeVerifier": proof.verifier], as: StockTradeSession.self)
        try checkedLogin(ticket, consoleContext: consoleContext)
        guard value.valid, let issuer = NativeApplicationAuthorization.origin(authentication.serverURL),
              NativeApplicationAuthorization.origin(value.user.issuer) == issuer,
              !value.user.subject.isEmpty, !value.user.id.isEmpty,
              let expiry = StockTradeTime.date(value.expiresAt), expiry.timeIntervalSinceNow <= 12 * 3600 + 5 else { throw StockTradeFailure.invalidResponse }
        try secrets.save(try JSONEncoder().encode(value), account: sessionKey, accessibility: .whenUnlocked)
        session = value; loadFavorites(); await refresh(); consent = nil
    }
    func logout() async {
        guard session != nil, !authenticating, !loading else { return }
        authenticating = true; error = nil
        let ticket = epoch
        defer { if ticket == epoch { authenticating = false } }
        do {
            struct Result: Decodable { let ok: Bool }
            let current = session!
            let response: Result = try await raw(["auth", "native", "logout"], method: "POST",
                body: ["deviceId": current.deviceId, "deviceToken": current.deviceToken, "deviceFingerprint": try deviceFingerprint()], as: Result.self)
            try checked(ticket)
            guard response.ok else { throw StockTradeFailure.invalidResponse }
            try secrets.delete(account: sessionKey); clearVisible(); explicitlyLoggedOut = true
        } catch {
            if ticket == epoch {
                if (error as? StockTradeFailure)?.invalidatesSession == true {
                    do { try secrets.delete(account: sessionKey); clearVisible(); explicitlyLoggedOut = true }
                    catch { self.error = error.localizedDescription }
                } else { self.error = "退出尚未确认，已保留会话供重试。" + error.localizedDescription }
            }
        }
    }
    func refresh() async {
        guard !loading, session != nil else { return }
        loading = true; error = nil
        let ticket = epoch, generation = resultGeneration
        defer { if ticket == epoch { loading = false } }
        do {
            let latest: StockTradeRun = try await read(["runs", displayedRunID ?? "latest"], as: StockTradeRun.self)
            try checked(ticket)
            guard latest.status == "complete" else { throw StockTradeFailure.invalidResponse }
            let page = try await resultPage(run: latest, pool: pool, cursor: nil)
            try checked(ticket)
            guard generation == resultGeneration else { return }
            run = latest; rows = page.items; nextCursor = page.nextCursor; updatedAt = .now; missingSnapshot = false
        } catch is CancellationError { }
        catch {
            if ticket == epoch {
                self.error = error.localizedDescription
                if let failure = error as? StockTradeFailure, case .api(_, let code, _, _) = failure {
                    missingSnapshot = code == "snapshot_unavailable"
                } else { missingSnapshot = false }
            }
        }
    }
    func selectPool(_ value: StockTradePool) async {
        guard !loading else { return }
        pool = value; rows = []; nextCursor = nil
        await loadResults(append: false)
    }
    func loadResults(append: Bool) async {
        guard !loading, let run, !append || nextCursor != nil else { return }
        loading = true; error = nil
        let ticket = epoch, selectedPool = pool, generation = resultGeneration
        defer { if ticket == epoch { loading = false } }
        do {
            let page = try await resultPage(run: run, pool: selectedPool, cursor: append ? nextCursor : nil)
            try checked(ticket)
            guard generation == resultGeneration, pool == selectedPool else { return }
            if append {
                guard Set(rows.map(\.symbol)).isDisjoint(with: page.items.map(\.symbol)) else { throw StockTradeFailure.invalidResponse }
                rows += page.items
            } else { rows = page.items }
            nextCursor = page.nextCursor
        } catch is CancellationError { }
        catch { if ticket == epoch { self.error = error.localizedDescription } }
    }
    private func resultPage(run: StockTradeRun, pool: StockTradePool, cursor: String?) async throws -> StockTradePage<StockTradeRecord> {
        var query = [URLQueryItem(name: "snapshotId", value: run.snapshotId), URLQueryItem(name: "limit", value: "50")]
        if let cursor { query.append(.init(name: "cursor", value: cursor)) }
        if pool != .candidates { query.append(.init(name: "pool", value: pool.rawValue)) }
        let page: StockTradePage<StockTradeRecord> = try await read(["runs", run.runId, pool == .candidates ? "candidates" : "recommendations"], query: query, as: StockTradePage<StockTradeRecord>.self)
        guard page.snapshotId == run.snapshotId, page.items.allSatisfy({ Self.validSymbol($0.symbol) }),
              Set(page.items.map(\.symbol)).count == page.items.count else { throw StockTradeFailure.invalidResponse }
        return page
    }
    static func validSymbol(_ value: String) -> Bool { value.range(of: #"^\d{6}\.(SH|SZ|BJ)$"#, options: .regularExpression) != nil }
    func toggleFavorite(_ record: StockTradeRecord) {
        guard Self.validSymbol(record.symbol), let key = favoriteKey else { return }
        var updated = favorites.filter { $0.symbol != record.symbol }
        if updated.count == favorites.count { updated.append(record) }
        do { defaults.set(try JSONEncoder().encode(updated), forKey: key); favorites = updated }
        catch { self.error = "自选未能保存，请重试。" }
    }
    private func loadFavorites() {
        guard let key = favoriteKey, let data = defaults.data(forKey: key) else { favorites = []; return }
        do { favorites = try JSONDecoder().decode([StockTradeRecord].self, from: data).filter { Self.validSymbol($0.symbol) } }
        catch { favorites = []; self.error = "本机自选无法读取，原记录已保留。" }
    }

    func refreshWorkflows(append: Bool = false) async {
        guard session != nil, !workflowsLoading, !append || workflowCursor != nil else { return }
        let ticket = epoch
        workflowsLoading = true
        defer { if ticket == epoch { workflowsLoading = false } }
        do {
            var query = [URLQueryItem(name: "limit", value: "50")]
            if append, let cursor = workflowCursor { query.append(.init(name: "cursor", value: cursor)) }
            let page = try await read(["tasks"], query: query, as: StockTradeWorkflowPage.self)
            try checked(ticket)
            let tasks = try page.items.map { try $0.validated() }
            guard Set(tasks.map(\.id)).count == tasks.count,
                  !append || Set(workflowTasks.map(\.id)).isDisjoint(with: tasks.map(\.id)) else { throw StockTradeFailure.invalidResponse }
            // First-page refresh preserves older loaded rows, and replaces their status by ID.
            let refreshedIDs = Set(tasks.map(\.id))
            let older = workflowTasks.filter { !refreshedIDs.contains($0.id) }
            workflowTasks = append ? workflowTasks + tasks : tasks + older
            if append || older.isEmpty { workflowCursor = page.nextCursor }
            workflowOnline = page.workerOnline; workflowError = nil
        } catch is CancellationError { }
        catch { if ticket == epoch { workflowError = error.localizedDescription } }
    }

    func workflowTask(_ id: String) async throws -> StockTradeWorkflowTask {
        let task = try await read(["tasks", id], as: StockTradeWorkflowTask.self).validated()
        guard task.id == id else { throw StockTradeFailure.invalidResponse }
        if let index = workflowTasks.firstIndex(where: { $0.id == id }) { workflowTasks[index] = task }
        return task
    }

    func submitWorkflow(kind: StockTradeWorkflowKind, dataDate: String?, requestID: String) async throws -> StockTradeWorkflowTask {
        var body = ["kind": kind.rawValue, "requestId": requestID]
        if let dataDate { body["dataDate"] = dataDate }
        let task = try await read(["tasks"], method: "POST", body: body, as: StockTradeWorkflowTask.self).validated()
        guard task.kind == kind, task.dataDate == dataDate else { throw StockTradeFailure.invalidResponse }
        workflowTasks.removeAll { $0.id == task.id }; workflowTasks.insert(task, at: 0)
        workflowError = nil
        return task
    }

    func openPublishedRun(_ id: String?) async throws {
        let ticket = epoch
        let generation = UUID(); resultGeneration = generation
        let value = try await read(["runs", id ?? "latest"], as: StockTradeRun.self)
        guard value.status == "complete", id == nil || value.runId == id else { throw StockTradeFailure.invalidResponse }
        let page = try await resultPage(run: value, pool: pool, cursor: nil)
        try checked(ticket)
        guard generation == resultGeneration else { throw CancellationError() }
        displayedRunID = id; run = value; rows = page.items; nextCursor = page.nextCursor; updatedAt = .now; error = nil; missingSnapshot = false
    }
}
