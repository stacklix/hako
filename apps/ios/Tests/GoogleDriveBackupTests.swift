import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@main struct GoogleDriveBackupTests {
    static let clientID = "12345-test.apps.googleusercontent.com"
    static let digest = "900150983cd24fb0d6963f7d28e17f72"

    @MainActor static func main() async throws {
        try pathsAndOAuth()
        try await uploadAndRefresh()
        try await rejectsUnsafeResponses()
        print("PASS: Drive OAuth state and PKCE parameters, path isolation, token refresh, resumable create/update, integrity verification and unsafe-response rejection")
    }

    static func rejects(_ action: () throws -> Void) {
        do { try action(); preconditionFailure("Invalid input accepted") } catch {}
    }

    static func pathsAndOAuth() throws {
        let callback = "com.googleusercontent.apps.12345-test:/oauthredirect?state=expected&code=secret"
        let code = try GoogleDriveOAuth.authorizationCode(URL(string: callback)!, clientID: clientID, state: "expected")
        precondition(code == "secret")
        for value in [callback + "&state=expected", callback + "&code=other", callback + "#fragment",
                      callback.replacingOccurrences(of: "expected", with: "other"),
                      callback.replacingOccurrences(of: "/oauthredirect?", with: "/other?"),
                      "com.googleusercontent.apps.12345-test:/oauthredirect?state=expected&error=access_denied"] {
            rejects { _ = try GoogleDriveOAuth.authorizationCode(URL(string: value)!, clientID: clientID, state: "expected") }
        }
        for id in ["", "client.example.com", "a/b.apps.googleusercontent.com", "x.apps.googleusercontent.com "] {
            rejects { _ = try GoogleDriveOAuth.redirectURI(clientID: id) }
        }
        let auth = try GoogleDriveOAuth.authorizationURL(clientID: clientID, state: "state", challenge: "challenge")
        let parameters = Dictionary(uniqueKeysWithValues: URLComponents(url: auth, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        precondition(parameters["code_challenge_method"] == "S256" && parameters["scope"] == GoogleDriveOAuth.scope)
        precondition(parameters["access_type"] == "offline" && parameters["prompt"] == "consent select_account")
        let body = String(decoding: GoogleDriveOAuth.form(["code": "a+b&c=d 空格"]), as: UTF8.self)
        precondition(body.contains("%2B") && body.contains("%26") && body.contains("%3D"))
        for path in ["../x", "/root", "root/", "a//b", "a\\b", " a", "a/..", "a\n"] {
            rejects { _ = try HakoBackupPath.components(path) }
        }
        let date = ISO8601DateFormatter().date(from: "2026-11-20T17:02:03Z")!
        let target = try HakoBackupFile(subdirectory: "投资/每日", fileName: "账本-{date}-{time}.zip").resolved(at: date)
        precondition(target.directories == ["投资", "每日"] && target.fileName == "账本-2026-11-21-010203000.zip")
        for name in ["", "../x.zip", "x/{date}.zip", "{unknown}.zip"] {
            rejects { _ = try HakoBackupFile(subdirectory: "", fileName: name).resolved() }
        }
        precondition(GoogleDrivePath.queryLiteral("a'b\\c") == "a\\'b\\\\c")
    }

    @MainActor final class Fixture {
        var credential: GoogleDriveCredential? = GoogleDriveCredential(clientID: clientID, accessToken: "expired",
            refreshToken: "refresh+secret", expiresAt: .distantPast)
        var requests: [URLRequest] = []
        var existing = false
        var duplicate = false
        var hostileLocation = false
        var invalidGrant = false
        var corrupt = false
        var lostUpload = false
        var folderCreates = 0
        var checkedParent = false
        lazy var client = GoogleDriveClient(send: { try self.send($0) }, read: { self.credential },
            save: { self.credential = $0 }, clear: { self.credential = nil }, checksum: { data in
                precondition(data == Data("abc".utf8)); return digest
            })

        func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
            requests.append(request)
            let url = request.url!
            var json: [String: Any] = [:]
            var headers: [String: String] = [:]
            var status = 200
            if url.path == "/token" {
                precondition(url.host == "oauth2.googleapis.com")
                if invalidGrant { json = ["error": "invalid_grant"]; status = 400 }
                else { json = ["access_token": "fresh", "expires_in": 3600, "scope": GoogleDriveOAuth.scope] }
            } else {
                precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh")
                if url.path == "/drive/v3/files", request.httpMethod == "GET" {
                    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "q" }!.value!
                    if query.contains("mimeType") {
                        checkedParent = query.contains("'root' in parents")
                        json = ["files": duplicate ? [["id": "one"], ["id": "two"]] : []]
                    } else {
                        precondition(query.contains("'folder' in parents") && query.contains("hako.application") && query.contains("investment"))
                        json = ["files": existing ? [["id": "backup"]] : []]
                    }
                } else if url.path == "/drive/v3/files", request.httpMethod == "POST" {
                    folderCreates += 1
                    let metadata = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                    precondition(metadata["parents"] as? [String] == ["root"])
                    json = ["id": "folder"]
                } else if url.path.hasPrefix("/upload/drive/v3/files"), request.httpMethod != "PUT" {
                    precondition(request.httpMethod == (existing ? "PATCH" : "POST"))
                    let metadata = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                    precondition(metadata["name"] as? String == "backup.zip")
                    precondition((metadata["parents"] == nil) == existing)
                    precondition(request.value(forHTTPHeaderField: "X-Upload-Content-Length") == "3")
                    headers["Location"] = hostileLocation ? "https://evil.example/upload" : "https://www.googleapis.com/upload/drive/v3/files?upload_id=session"
                } else if request.httpMethod == "PUT" {
                    precondition(request.httpBody == Data("abc".utf8))
                    if lostUpload { throw URLError(.networkConnectionLost) }
                    json = ["id": "backup"]
                } else if url.path == "/drive/v3/files/backup" {
                    json = ["id": "backup", "size": "3", "md5Checksum": corrupt ? "wrong" : digest]
                } else { preconditionFailure("Unexpected request \(request.httpMethod ?? "") \(url.path)") }
            }
            return (try JSONSerialization.data(withJSONObject: json), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!)
        }

        func backup() async throws -> GoogleDriveBackupReceipt {
            try await client.backup(data: Data("abc".utf8), applicationID: "investment",
                destination: HakoBackupFile(subdirectory: "", fileName: "backup.zip"),
                settings: GoogleDriveSettings(clientID: clientID, parentDirectory: "Hako"), mimeType: "application/zip")
        }
    }

    @MainActor static func uploadAndRefresh() async throws {
        for existing in [false, true] {
            let fixture = Fixture(); fixture.existing = existing
            let receipt = try await fixture.backup()
            precondition(receipt.path == "Hako/backup.zip" && receipt.byteCount == 3)
            precondition(fixture.checkedParent && fixture.folderCreates == 1)
            precondition(fixture.credential?.refreshToken == "refresh+secret")
            precondition(fixture.requests.filter { $0.url?.path == "/token" }.count == 1)
            precondition(fixture.requests.filter { $0.httpMethod == "PUT" }.count == 1)
        }
    }

    @MainActor static func rejectsUnsafeResponses() async throws {
        for scenario in 0..<5 {
            let fixture = Fixture()
            fixture.duplicate = scenario == 0; fixture.hostileLocation = scenario == 1
            fixture.invalidGrant = scenario == 2; fixture.corrupt = scenario == 3; fixture.lostUpload = scenario == 4
            do { _ = try await fixture.backup(); preconditionFailure("Unsafe response accepted") } catch {}
            if scenario == 0 || scenario == 1 { precondition(!fixture.requests.contains { $0.httpMethod == "PUT" }) }
            if scenario == 2 { precondition(fixture.credential == nil && fixture.requests.count == 1) }
            if scenario == 4 { precondition(fixture.requests.filter { $0.httpMethod == "PUT" }.count == 1, "Write was replayed") }
        }
    }
}
