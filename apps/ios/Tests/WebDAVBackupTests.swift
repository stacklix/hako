import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@main struct WebDAVBackupTests {
    @MainActor final class Fixture {
        var calls: [URLRequest] = []
        var corrupt = false
        var denied = false
        var lost = false
        var wrongHref = false
        var badProperty = false
        let data = Data("archive-content".utf8)
        let settings = WebDAVBackupSettings(serverURL: "https://nas.example/dav/account/", username: "backup")
        lazy var client = WebDAVBackupClient(send: { try self.send($0) })
        func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
            calls.append(request)
            precondition(request.url!.host == "nas.example")
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("backup:secret".utf8).base64EncodedString())
            var body = Data(), status = 200
            switch request.httpMethod! {
            case "PROPFIND":
                precondition(request.value(forHTTPHeaderField: "Depth") == "0")
                let href = wrongHref ? "https://evil.example/dav/account/" : "/dav/account/"
                let propertyStatus = badProperty ? "404 Not Found" : "200 OK"
                body = Data("<?xml version=\"1.0\"?><d:multistatus xmlns:d=\"DAV:\"><d:response><d:href>\(href)</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 \(propertyStatus)</d:status></d:propstat></d:response></d:multistatus>".utf8)
                status = 207
            case "MKCOL": status = denied ? 401 : request.url!.path.hasSuffix("Hako") || request.url!.path.hasSuffix("Hako/") ? 405 : 201
            case "PUT":
                precondition(request.httpBody == data)
                if lost { throw URLError(.networkConnectionLost) }
                status = 201
            case "GET": body = corrupt ? Data("wrong".utf8) : data
            default: preconditionFailure("Unexpected method")
            }
            return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        func backup() async throws -> String {
            try await client.backup(data: data, target: HakoBackupTarget(name: "NAS", provider: .webDAV, webDAV: settings),
                file: HakoBackupFile(subdirectory: "投资 记账", fileName: "backup.zip"), mimeType: "application/zip", password: "secret", at: Date())
        }
    }

    @MainActor static func main() async throws {
        let fixture = Fixture()
        try await fixture.client.check(settings: fixture.settings, password: "secret")
        let path = try await fixture.backup()
        precondition(path == "Hako/投资 记账/backup.zip")
        precondition(fixture.calls.map(\.httpMethod) == ["PROPFIND", "MKCOL", "MKCOL", "PUT", "GET"])
        precondition(fixture.calls.last!.url!.absoluteString.contains("%20"))
        for scenario in 0..<5 {
            let fixture = Fixture()
            fixture.corrupt = scenario == 0; fixture.denied = scenario == 1; fixture.lost = scenario == 2
            fixture.wrongHref = scenario == 3; fixture.badProperty = scenario == 4
            do {
                if scenario >= 3 { try await fixture.client.check(settings: fixture.settings, password: "secret") }
                else { _ = try await fixture.backup() }
                preconditionFailure("Invalid WebDAV response accepted")
            } catch {}
            if scenario == 1 { precondition(!fixture.calls.contains { $0.httpMethod == "PUT" }) }
            if scenario == 2 { precondition(fixture.calls.filter { $0.httpMethod == "PUT" }.count == 1) }
        }
        for value in ["https://user:secret@nas.example/dav/", "https://nas.example/dav/?token=secret", "ftp://nas.example/dav/"] {
            do { _ = try WebDAVBackupSettings(serverURL: value).baseURL(); preconditionFailure("Invalid endpoint accepted") } catch {}
        }
        print("PASS: WebDAV directory authentication, recursive MKCOL, encoded paths, upload read-back verification, denied access, uncertain writes and hostile PROPFIND responses")
    }
}
