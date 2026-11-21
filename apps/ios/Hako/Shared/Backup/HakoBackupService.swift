import Combine
import Foundation

@MainActor final class HakoBackupService: ObservableObject, HakoDataBackupAccess {
    static let shared = HakoBackupService()
    @Published private(set) var targets: [HakoBackupTarget] = []
    @Published private(set) var busy = false
    @Published private(set) var storageIssue: String?
    private let storageKey = "hako.data-backup.targets"
    private let passwords = SecureStorage.namespace("me.stackli.hako.backups.webdav")

    private init() {
        if let data = UserDefaults.standard.data(forKey: storageKey) {
            do { targets = try JSONDecoder().decode([HakoBackupTarget].self, from: data) }
            catch { storageIssue = "无法读取备份目的地配置，请检查本机存储。" }
        }
    }

    func save(_ target: HakoBackupTarget, password: String?) throws {
        guard !busy else { throw HakoBackupError(message: "备份正在执行，请稍后修改目的地。") }
        guard storageIssue == nil else { throw HakoBackupError(message: storageIssue!) }
        try target.validate()
        if target.provider == .webDAV {
            if let password, !password.isEmpty {
                try passwords.save(Data(password.utf8), account: target.id.uuidString, accessibility: .afterFirstUnlock)
            } else { _ = try webDAVPassword(target.id) }
        }
        var updated = targets
        if let index = updated.firstIndex(where: { $0.id == target.id }) { updated[index] = target }
        else { updated.append(target) }
        UserDefaults.standard.set(try JSONEncoder().encode(updated), forKey: storageKey)
        targets = updated
    }

    func remove(_ id: UUID) throws {
        guard !busy else { throw HakoBackupError(message: "备份正在执行，请稍后移除目的地。") }
        guard storageIssue == nil else { throw HakoBackupError(message: storageIssue!) }
        try passwords.delete(account: id.uuidString)
        let updated = targets.filter { $0.id != id }
        UserDefaults.standard.set(try JSONEncoder().encode(updated), forKey: storageKey)
        targets = updated
    }

    func checkWebDAV(_ target: HakoBackupTarget, password: String?) async throws {
        let secret: String
        if let password, !password.isEmpty { secret = password }
        else { secret = try webDAVPassword(target.id) }
        try await WebDAVBackupClient(send: Self.send).check(settings: target.webDAV, password: secret)
    }

    func latestReport(applicationID: String) -> HakoBackupReport? {
        UserDefaults.standard.data(forKey: "hako.data-backup.report.\(applicationID)")
            .flatMap { try? JSONDecoder().decode(HakoBackupReport.self, from: $0) }
    }

    func backup(data: Data, applicationID: String, file: HakoBackupFile, mimeType: String, at date: Date) async throws -> HakoBackupReport {
        guard !busy else { throw HakoBackupError(message: "已有数据备份正在执行，请稍后重试。") }
        guard storageIssue == nil else { throw HakoBackupError(message: storageIssue!) }
        busy = true
        defer { busy = false }
        let coordinator = HakoBackupCoordinator(upload: { target, data, app, file, mime, date in
            switch target.provider {
            case .googleDrive:
                return try await GoogleDriveBackupService.shared.backup(data: data, applicationID: app, target: target,
                    file: file, mimeType: mime, at: date).path
            case .webDAV:
                return try await WebDAVBackupClient(send: Self.send).backup(data: data, target: target, file: file,
                    mimeType: mime, password: self.webDAVPassword(target.id), at: date)
            }
        }, record: { report in
            UserDefaults.standard.set(try JSONEncoder().encode(report), forKey: "hako.data-backup.report.\(applicationID)")
        })
        return try await coordinator.backup(targets: targets, data: data, applicationID: applicationID, file: file, mimeType: mimeType, at: date)
    }

    private func webDAVPassword(_ id: UUID) throws -> String {
        guard let data = try passwords.read(account: id.uuidString), let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            throw HakoBackupError(message: "请在主应用配置此 WebDAV 目的地的密码。")
        }
        return value
    }

    private static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        // Bypass body logging; the shared session still rejects redirects and uses the common network policy.
        let (data, response) = try await HTTPTransport.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw HakoBackupError(message: "备份目的地未返回有效响应。") }
        return (data, response)
    }
}
