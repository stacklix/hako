import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// No browser, child-app types or server credentials enter this transport.
@MainActor final class GoogleDriveClient {
    typealias Send = (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let send: Send
    private let readCredential: () throws -> GoogleDriveCredential?
    private let saveCredential: (GoogleDriveCredential) throws -> Void
    private let clearCredential: () throws -> Void
    private let checksum: (Data) -> String

    init(send: @escaping Send, read: @escaping () throws -> GoogleDriveCredential?,
         save: @escaping (GoogleDriveCredential) throws -> Void, clear: @escaping () throws -> Void,
         checksum: @escaping (Data) -> String) {
        self.send = send; readCredential = read; saveCredential = save; clearCredential = clear
        self.checksum = checksum
    }

    func exchange(code: String, verifier: String, clientID: String) async throws {
        let credential = try await requestToken(fields: ["client_id": clientID, "code": code,
            "code_verifier": verifier, "redirect_uri": try GoogleDriveOAuth.redirectURI(clientID: clientID),
            "grant_type": "authorization_code"], clientID: clientID, previous: nil)
        try saveCredential(credential)
    }

    func disconnect() async throws {
        if let credential = try readCredential() {
            var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = GoogleDriveOAuth.form(["token": credential.refreshToken])
            let (_, response) = try await send(request)
            guard response.statusCode == 200 else { throw GoogleDriveError(message: "Google 撤销授权失败（HTTP \(response.statusCode)），请重试。") }
        }
        try clearCredential()
    }

    func backup(data: Data, applicationID: String, destination: HakoBackupFile,
                settings: GoogleDriveSettings, mimeType: String, at date: Date = Date()) async throws -> GoogleDriveBackupReceipt {
        try settings.validate()
        guard !applicationID.isEmpty, applicationID.utf8.count <= 100, !data.isEmpty else {
            throw GoogleDriveError(message: "备份内容或子应用标识无效。")
        }
        let resolved = try destination.resolved(at: date)
        let directories = try HakoBackupPath.components(settings.parentDirectory) + resolved.directories
        let token = try await accessToken(clientID: settings.clientID)
        var parent = "root"
        for directory in directories {
            try Task.checkCancellation()
            let query = "'\(GoogleDrivePath.queryLiteral(parent))' in parents and trashed = false and name = '\(GoogleDrivePath.queryLiteral(directory))' and mimeType = 'application/vnd.google-apps.folder'"
            if let folder = try await find(query: query, token: token) { parent = folder.id }
            else {
                let result = try await api("files", method: "POST", token: token,
                    json: ["name": directory, "mimeType": "application/vnd.google-apps.folder", "parents": [parent]])
                parent = try JSONDecoder().decode(DriveFile.self, from: result).id
            }
        }
        let query = "'\(GoogleDrivePath.queryLiteral(parent))' in parents and trashed = false and name = '\(GoogleDrivePath.queryLiteral(resolved.fileName))' and appProperties has { key='hako.application' and value='\(GoogleDrivePath.queryLiteral(applicationID))' }"
        let existing = try await find(query: query, token: token)
        var metadata: [String: Any] = ["name": resolved.fileName, "appProperties": ["hako.application": applicationID]]
        if existing == nil { metadata["parents"] = [parent] }
        let path = existing.map { "files/\(Self.pathID($0.id))" } ?? "files"
        let url = URL(string: "https://www.googleapis.com/upload/drive/v3/\(path)?uploadType=resumable")!
        var start = URLRequest(url: url, timeoutInterval: 60)
        start.httpMethod = existing == nil ? "POST" : "PATCH"
        start.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        start.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        start.setValue(mimeType, forHTTPHeaderField: "X-Upload-Content-Type")
        start.setValue(String(data.count), forHTTPHeaderField: "X-Upload-Content-Length")
        start.httpBody = try JSONSerialization.data(withJSONObject: metadata)
        let (_, response) = try await checked(start)
        guard let location = response.value(forHTTPHeaderField: "Location"), let uploadURL = URL(string: location),
              uploadURL.scheme == "https", ["www.googleapis.com", "content.googleapis.com"].contains(uploadURL.host ?? ""),
              uploadURL.user == nil, uploadURL.password == nil, uploadURL.port == nil,
              uploadURL.path.hasPrefix("/upload/drive/v3/files") else {
            throw GoogleDriveError(message: "Google 返回的上传地址无效，已停止上传。")
        }
        try Task.checkCancellation()
        var upload = URLRequest(url: uploadURL, timeoutInterval: 180)
        upload.httpMethod = "PUT"
        upload.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        upload.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        upload.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        upload.httpBody = data
        // Never replay a write automatically: a lost response can mean it already succeeded.
        let (result, _) = try await checked(upload)
        let file = try JSONDecoder().decode(DriveFile.self, from: result)
        let verification = try await api("files/\(Self.pathID(file.id))", token: token,
            query: ["fields": "id,size,md5Checksum"])
        let verified = try JSONDecoder().decode(DriveFile.self, from: verification)
        guard verified.id == file.id, verified.size == String(data.count), verified.md5Checksum == checksum(data) else {
            throw GoogleDriveError(message: "文件已上传，但大小或校验和不匹配，请检查 Drive 中的备份。")
        }
        return GoogleDriveBackupReceipt(fileID: file.id, path: (directories + [resolved.fileName]).joined(separator: "/"),
            byteCount: data.count, completedAt: Date())
    }

    private struct DriveFile: Decodable {
        let id: String
        var size: String?
        var md5Checksum: String?
    }
    private struct DriveList: Decodable { let files: [DriveFile]; var nextPageToken: String? }

    private func find(query: String, token: String) async throws -> DriveFile? {
        let data = try await api("files", token: token, query: ["q": query, "pageSize": "2", "fields": "files(id),nextPageToken", "spaces": "drive"])
        let list = try JSONDecoder().decode(DriveList.self, from: data)
        guard list.files.count <= 1, list.nextPageToken == nil else {
            throw GoogleDriveError(message: "Drive 中存在多个同名目录或备份，请先整理或更换名称。")
        }
        return list.files.first
    }

    private func accessToken(clientID: String) async throws -> String {
        guard let credential = try readCredential(), credential.clientID == clientID else {
            throw GoogleDriveError(message: "请先在主应用设置中连接 Google Drive。")
        }
        if credential.expiresAt.timeIntervalSinceNow > 240 { return credential.accessToken }
        let updated = try await requestToken(fields: ["client_id": clientID, "refresh_token": credential.refreshToken,
            "grant_type": "refresh_token"], clientID: clientID, previous: credential)
        try saveCredential(updated)
        return updated.accessToken
    }

    private func requestToken(fields: [String: String], clientID: String, previous: GoogleDriveCredential?) async throws -> GoogleDriveCredential {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = GoogleDriveOAuth.form(fields)
        let (data, response) = try await send(request)
        struct Token: Decodable {
            var access_token: String?; var refresh_token: String?; var expires_in: Double?
            var scope: String?; var error: String?
        }
        let result = try? JSONDecoder().decode(Token.self, from: data)
        if result?.error == "invalid_grant", previous != nil {
            try clearCredential()
            throw GoogleDriveError(message: "Google Drive 授权已失效，请在主应用设置中重新连接。")
        }
        guard response.statusCode == 200, let access = result?.access_token, !access.isEmpty,
              let refresh = result?.refresh_token ?? previous?.refreshToken, !refresh.isEmpty,
              let duration = result?.expires_in, duration > 0 else {
            throw GoogleDriveError(message: "无法取得 Google Drive 授权（HTTP \(response.statusCode)），请检查 Client ID 和授权配置。")
        }
        if let scope = result?.scope, !scope.split(separator: " ").contains(Substring(GoogleDriveOAuth.scope)) {
            throw GoogleDriveError(message: "Google 未授予备份文件权限，请重新连接并允许 Drive 访问。")
        }
        return GoogleDriveCredential(clientID: clientID, accessToken: access, refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(duration))
    }

    private func api(_ path: String, method: String = "GET", token: String,
                     query: [String: String] = [:], json: [String: Any]? = nil) async throws -> Data {
        var url = URLComponents(string: "https://www.googleapis.com/drive/v3/" + path)!
        if !query.isEmpty { url.queryItems = query.map(URLQueryItem.init) }
        var request = URLRequest(url: url.url!, timeoutInterval: 60)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let json {
            request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        return try await checked(request).0
    }

    private func checked(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let (data, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else {
            let message: String
            switch response.statusCode {
            case 401: message = "Google Drive 登录已过期，请重新连接后重试。"
            case 403: message = "Google Drive 拒绝访问，请检查 API 是否启用、授权权限和剩余空间。"
            case 429: message = "Google Drive 请求过于频繁，请稍后重试。"
            default: message = "Google Drive 请求失败（HTTP \(response.statusCode)）。上传响应丢失时，请先检查云端文件。"
            }
            throw GoogleDriveError(message: message)
        }
        return (data, response)
    }

    private static func pathID(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")))!
    }
}
