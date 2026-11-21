import AuthenticationServices
import Combine
import CryptoKit
import Foundation
import Security
import UIKit

// Host adapter. Destinations can share a connection; credentials are isolated by connection ID.
@MainActor final class GoogleDriveBackupService: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = GoogleDriveBackupService()
    @Published private(set) var connections: [GoogleDriveConnectionSettings] = []
    @Published private(set) var connectedIDs: Set<UUID> = []
    @Published private(set) var busy = false
    @Published private(set) var storageIssue: String?
    private var authenticationSession: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?
    private var authorizationID: UUID?
    private var anchor: UIWindow?
    private let storageKey = "google-drive.connections"
    private static let secrets = SecureStorage.namespace("me.stackli.hako.google-drive")

    private override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: storageKey) {
            do { connections = try JSONDecoder().decode([GoogleDriveConnectionSettings].self, from: data) }
            catch { storageIssue = "无法读取 Google Drive 连接配置，请检查本机存储。" }
        }
        refreshConnections()
    }

    private static func readCredential(_ id: UUID) throws -> GoogleDriveCredential? {
        guard let data = try secrets.read(account: id.uuidString) else { return nil }
        return try JSONDecoder().decode(GoogleDriveCredential.self, from: data)
    }
    private func refreshConnections() {
        connectedIDs = Set(connections.filter { connection in
            (try? Self.readCredential(connection.id))?.clientID == connection.clientID
        }.map(\.id))
    }
    private func makeClient(_ id: UUID) -> GoogleDriveClient {
        GoogleDriveClient(send: { request in
            let (data, response) = try await HTTPTransport.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw GoogleDriveError(message: "Google Drive 未返回有效响应。") }
            return (data, response)
        }, read: { try Self.readCredential(id) }, save: {
            try Self.secrets.save(JSONEncoder().encode($0), account: id.uuidString, accessibility: .afterFirstUnlock)
        }, clear: { try Self.secrets.delete(account: id.uuidString) }, checksum: {
            Insecure.MD5.hash(data: $0).map { String(format: "%02x", $0) }.joined()
        })
    }

    func save(_ value: GoogleDriveConnectionSettings) throws {
        guard !busy, !HakoBackupService.shared.busy else { throw GoogleDriveError(message: "正在执行备份或授权，请稍后保存。") }
        guard storageIssue == nil else { throw GoogleDriveError(message: storageIssue!) }
        try value.validate()
        if connectedIDs.contains(value.id), connections.first(where: { $0.id == value.id })?.clientID != value.clientID {
            throw GoogleDriveError(message: "请先断开此连接，再更换 Client ID。")
        }
        var updated = connections
        if let index = updated.firstIndex(where: { $0.id == value.id }) { updated[index] = value }
        else { updated.append(value) }
        UserDefaults.standard.set(try JSONEncoder().encode(updated), forKey: storageKey)
        connections = updated
        refreshConnections()
    }

    func connect(_ value: GoogleDriveConnectionSettings) async throws {
        try save(value)
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .filter({ $0.activationState == .foregroundActive }).flatMap(\.windows).first(where: \.isKeyWindow) else {
            throw GoogleDriveError(message: "请在主应用前台连接 Google Drive。")
        }
        busy = true; anchor = window
        defer { busy = false; anchor = nil; authenticationSession = nil; refreshConnections() }
        let verifier = try Self.randomString(), state = try Self.randomString()
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let url = try GoogleDriveOAuth.authorizationURL(clientID: value.clientID, state: state, challenge: challenge)
        let redirect = URL(string: try GoogleDriveOAuth.redirectURI(clientID: value.clientID))!
        let authorizationID = UUID()
        let callback: URL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                self.authorizationID = authorizationID
                let session = ASWebAuthenticationSession(url: url, callbackURLScheme: redirect.scheme) { url, _ in
                    Task { @MainActor in
                        self.finishAuthorization(url.map(Result.success) ?? .failure(GoogleDriveError(message: "Google Drive 授权未完成或已取消。")), id: authorizationID)
                    }
                }
                session.presentationContextProvider = self
                self.authenticationSession = session
                if !session.start() { finishAuthorization(.failure(GoogleDriveError(message: "无法打开 Google 授权窗口。")), id: authorizationID) }
            }
        } onCancel: {
            Task { @MainActor in
                self.authenticationSession?.cancel()
                self.finishAuthorization(.failure(CancellationError()), id: authorizationID)
            }
        }
        try Task.checkCancellation()
        let code = try GoogleDriveOAuth.authorizationCode(callback, clientID: value.clientID, state: state)
        try await makeClient(value.id).exchange(code: code, verifier: verifier, clientID: value.clientID)
    }
    private func finishAuthorization(_ result: Result<URL, Error>, id: UUID) {
        guard authorizationID == id, let continuation else { return }
        self.continuation = nil
        authorizationID = nil
        continuation.resume(with: result)
    }

    func disconnect(_ id: UUID) throws {
        guard !busy, !HakoBackupService.shared.busy else { throw GoogleDriveError(message: "正在执行备份或授权，请稍后断开连接。") }
        // Local sign-out preserves other connections authorized for the same Google account.
        try Self.secrets.delete(account: id.uuidString)
        refreshConnections()
    }
    func remove(_ id: UUID) throws {
        guard !HakoBackupService.shared.targets.contains(where: { $0.googleDriveConnectionID == id && $0.provider == .googleDrive }) else {
            throw GoogleDriveError(message: "请先移除或修改使用此连接的备份目的地。")
        }
        try disconnect(id)
        let updated = connections.filter { $0.id != id }
        UserDefaults.standard.set(try JSONEncoder().encode(updated), forKey: storageKey)
        connections = updated
    }

    func backup(data: Data, applicationID: String, target: HakoBackupTarget, file: HakoBackupFile,
                mimeType: String, at date: Date) async throws -> GoogleDriveBackupReceipt {
        guard !busy else { throw GoogleDriveError(message: "已有 Google Drive 操作正在执行，请稍后重试。") }
        guard let id = target.googleDriveConnectionID, let connection = connections.first(where: { $0.id == id }) else {
            throw GoogleDriveError(message: "请在主应用为此目的地配置 Google Drive 连接。")
        }
        busy = true
        defer { busy = false; refreshConnections() }
        return try await makeClient(id).backup(data: data, applicationID: applicationID, destination: file,
            settings: GoogleDriveSettings(clientID: connection.clientID, parentDirectory: target.parentDirectory), mimeType: mimeType, at: date)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { anchor! }
    private static func randomString() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw GoogleDriveError(message: "无法生成安全的授权请求。") }
        return base64URL(Data(bytes))
    }
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
