import Foundation

enum HakoBackupProvider: String, Codable, CaseIterable, Identifiable {
    case googleDrive, webDAV
    var id: Self { self }
    var title: String { self == .googleDrive ? "Google Drive" : "WebDAV" }
}

struct WebDAVBackupSettings: Codable, Equatable {
    var serverURL = ""
    var username = ""

    func baseURL() throws -> URL {
        guard let parts = URLComponents(string: serverURL), ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
              parts.host?.isEmpty == false, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, let url = parts.url else {
            throw HakoBackupError(message: "请输入 WebDAV 目录的完整 HTTP/HTTPS 地址，不要在地址中包含密码、查询参数或片段。")
        }
        return url
    }
}

struct HakoBackupTarget: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = ""
    var enabled = true
    var provider = HakoBackupProvider.googleDrive
    var parentDirectory = "Hako"
    var googleDriveConnectionID: UUID?
    var webDAV = WebDAVBackupSettings()

    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw HakoBackupError(message: "请填写目的地名称。") }
        let directories = try HakoBackupPath.components(parentDirectory)
        switch provider {
        case .googleDrive:
            guard googleDriveConnectionID != nil, !directories.isEmpty else {
                throw HakoBackupError(message: "请选择 Google Drive 连接并填写父目录。")
            }
        case .webDAV:
            _ = try webDAV.baseURL()
            guard !webDAV.username.isEmpty, !webDAV.username.contains(":") else { throw HakoBackupError(message: "请填写不含冒号的 WebDAV 用户名。") }
        }
    }
}

// Pure coordinator: every enabled destination is attempted, including after another one fails.
@MainActor struct HakoBackupCoordinator {
    typealias Upload = (HakoBackupTarget, Data, String, HakoBackupFile, String, Date) async throws -> String
    let upload: Upload
    var record: (HakoBackupReport) throws -> Void

    func backup(targets: [HakoBackupTarget], data: Data, applicationID: String,
                file: HakoBackupFile, mimeType: String, at date: Date) async throws -> HakoBackupReport {
        let enabled = targets.filter(\.enabled)
        guard !enabled.isEmpty else { throw HakoBackupError(message: "请先在主应用“数据备份”中添加并启用至少一个备份目的地。") }
        guard !data.isEmpty, !applicationID.isEmpty, applicationID.utf8.count <= 100 else { throw HakoBackupError(message: "备份内容或子应用标识无效。") }
        _ = try file.resolved(at: date)
        var results: [HakoBackupReport.Destination] = []
        for target in enabled {
            try Task.checkCancellation()
            do {
                try target.validate()
                let path = try await upload(target, data, applicationID, file, mimeType, date)
                results.append(.init(id: target.id, name: target.name, path: path, failure: nil))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                results.append(.init(id: target.id, name: target.name, path: nil, failure: error.localizedDescription))
            }
            // Preserve the successful destinations even if a later upload is interrupted.
            try record(HakoBackupReport(completedAt: Date(), byteCount: data.count, expectedCount: enabled.count, destinations: results))
        }
        let report = HakoBackupReport(completedAt: Date(), byteCount: data.count, expectedCount: enabled.count, destinations: results)
        if !report.succeeded { throw HakoBackupError(message: report.message) }
        return report
    }
}
