import Foundation
import Combine

@MainActor final class ConsoleApplicationsClient: ObservableObject {
    private let authentication: any AuthenticatedServerAccess
    private var subscription: AnyCancellable?
    private struct Snapshot { var context = ""; var applications: [ConsoleApplication] = []; var loaded = false }
    @Published private var snapshot = Snapshot()
    @Published private(set) var working = false
    init(authentication: (any AuthenticatedServerAccess)? = nil) {
        self.authentication = authentication ?? AuthenticatedServerService.shared
        subscription = self.authentication.changes.sink { [weak self] _ in self?.objectWillChange.send() }
    }
    var context: String { authentication.requestContext }
    var serverURL: String { authentication.serverURL }
    var authenticated: Bool { authentication.authenticated && !authentication.logoutPending }
    var busy: Bool { working || authentication.busy }
    var applications: [ConsoleApplication] { authenticated && snapshot.context == context ? snapshot.applications : [] }
    var loaded: Bool { authenticated && snapshot.context == context && snapshot.loaded }
    func restore() async { await authentication.restore() }
    private func requireContext(_ expected: String) throws {
        guard expected == context else { throw CancellationError() }
        guard authenticated else { throw ConsoleApplicationError.loginRequired }
    }
    private func request(_ path: String = "", method: String = "GET", body: [String: Any]? = nil) async throws -> Data {
        let expected = context
        try requireContext(expected)
        do {
            let data = try await authentication.send("/api/v1/applications" + path, method: method, body: body, logSource: .hako)
            try requireContext(expected)
            return data
        } catch {
            guard expected == context else { throw CancellationError() }
            if let failure = error as? ServerHTTPError {
                switch failure.code {
                case "invalid_application_details": throw HakoError(message: "应用信息或 OIDC 配置无效，请检查来源、精确回调地址和认证选项。")
                case "too_many_applications": throw HakoError(message: "最多支持 64 个应用。")
                case "application_not_found": throw HakoError(message: "应用已不存在，请返回并刷新列表。")
                default:
                    if failure.status == 404 { throw HakoError(message: "服务端尚不支持原生应用管理，请先更新 Hako 服务端。") }
                    throw failure
                }
            }
            if method != "GET" { throw HakoError(message: "请求结果尚未确认，请先刷新应用列表核对，再决定是否重试。若 Secret 响应遗失，需要轮换生成新值。") }
            throw error
        }
    }
    func refresh() async throws {
        guard !busy else { return }
        working = true; defer { working = false }
        let expected = context
        let result = try JSONDecoder().decode(ConsoleApplicationList.self, from: await request())
        guard result.issuer == serverURL else { throw ConsoleApplicationError.invalidResponse }
        try requireContext(expected)
        snapshot = Snapshot(context: expected, applications: result.applications, loaded: true)
    }
    private func upsert(_ value: ConsoleApplication) {
        if snapshot.context != context { snapshot = Snapshot(context: context) }
        if let index = snapshot.applications.firstIndex(where: { $0.id == value.id }) { snapshot.applications[index] = value }
        else { snapshot.applications.insert(value, at: 0) }
        snapshot.loaded = true
    }
    func create(_ draft: ConsoleApplicationDraft) async throws -> ConsoleApplicationCredential {
        let body = try draft.creationBody()
        return try await secretRequest(path: "", body: body)
    }
    func rotate(_ application: ConsoleApplication) async throws -> ConsoleApplicationCredential {
        try await secretRequest(path: "/\(application.id)/rotate", body: [:])
    }
    private func secretRequest(path: String, body: [String: Any]) async throws -> ConsoleApplicationCredential {
        guard !busy else { throw ConsoleApplicationError.busy }
        working = true; defer { working = false }
        let expected = context, issuer = serverURL
        let data = try await request(path, method: "POST", body: body)
        guard let result = try? JSONDecoder().decode(ConsoleApplicationSecretResponse.self, from: data),
              ConsoleWebLoginPayload.validID(result.clientSecret) else {
            throw HakoError(message: "应用可能已创建或轮换，但凭据响应无法读取。请刷新列表核对，并在需要时轮换 Secret；不要重复创建。")
        }
        try requireContext(expected)
        upsert(result.application)
        return ConsoleApplicationCredential(application: result.application, secret: result.clientSecret, issuer: issuer, context: expected)
    }
    func updateOIDC(_ application: ConsoleApplication, draft: ConsoleApplicationDraft) async throws {
        try await update(application, body: draft.updateBody())
    }
    func setEnabled(_ application: ConsoleApplication, enabled: Bool) async throws {
        try await update(application, body: ["enabled": enabled])
    }
    private func update(_ application: ConsoleApplication, body: [String: Any]) async throws {
        guard !busy else { throw ConsoleApplicationError.busy }
        working = true; defer { working = false }
        let result = try JSONDecoder().decode(ConsoleApplicationResult.self, from: await request("/\(application.id)", method: "PATCH", body: body))
        upsert(result.application)
    }
}
