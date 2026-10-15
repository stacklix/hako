import Foundation

final class MockProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, data) = try Self.handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
@main struct GitHubTests {
    static func main() async throws {
        let parsed = try GitHubSettings(repositoryURL: " https://github.com/stackli/hako.git/ ").repository()
        precondition(parsed.owner == "stackli" && parsed.name == "hako")
        for invalid in ["", "https://example.com/a/b", "https://github.com/a/b/tree/main", "https://github.com/a/b?x=1", "https://github.com/a/..", "https://github.com/a/%20b", "https://user:pass@github.com/a/b"] {
            do { try GitHubSettings(repositoryURL: invalid).validate(); fatalError("Accepted invalid repository URL") } catch is HakoError { }
        }
        precondition(GitHubSettings().branch == "master")
        for branch in ["", "bad branch", "main\n"] {
            do { try GitHubSettings(repositoryURL: "https://github.com/owner/repo", branch: branch).validate(); fatalError("Accepted invalid branch") } catch is HakoError { }
        }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockProtocol.self]
        let settings = GitHubSettings(repositoryURL: "https://github.com/owner/repo.git", branch: "data/main")
        let client = GitHubClient(settings: settings, token: "test-token", session: URLSession(configuration: config))
        func row(_ day: String, _ seconds: String = "120") -> [String] {
            [day, "Asia/Shanghai", seconds] + Array(repeating: "", count: 10)
        }
        func json(_ object: [String: Any]) throws -> (Int, Data) { (200, try JSONSerialization.data(withJSONObject: object)) }
        func snapshot(_ text: String? = nil, head: String = "head-1") throws -> (Int, Data) {
            let file: Any = text.map { ["object": ["text": $0, "isBinary": false, "isTruncated": false]] as [String: Any] } ?? NSNull()
            return try json(["data": ["repository": ["ref": ["target": ["oid": head, "file": file]]]]])
        }
        func success(signed: Bool = true) throws -> (Int, Data) {
            try json(["data": ["createCommitOnBranch": ["commit": ["oid": "new-commit", "signature": ["isValid": signed, "wasSignedByGitHub": signed]]]]])
        }
        func body(_ request: URLRequest) throws -> [String: Any] {
            precondition(request.url!.absoluteString == "https://api.github.com/graphql")
            precondition(request.httpMethod == "POST")
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count == 0 { break }
                    guard count > 0 else { throw HakoError(message: "Cannot read test request") }
                    data.append(contentsOf: buffer.prefix(count))
                }
            }
            return try JSONSerialization.jsonObject(with: data) as! [String: Any]
        }
        var calls = 0
        MockProtocol.handler = { req in
            calls += 1
            let payload = try body(req)
            let variables = payload["variables"] as! [String: Any]
            if (payload["query"] as! String).contains("query HakoSnapshot") {
                precondition(variables["ref"] as? String == "refs/heads/data/main")
                precondition(variables["path"] as? String == "data/screen-time/2026.csv")
                return try snapshot()
            }
            let input = variables["input"] as! [String: Any]
            precondition(input["expectedHeadOid"] as? String == "head-1")
            let branch = input["branch"] as! [String: String]
            precondition(branch["branchName"] == "data/main" && branch["repositoryNameWithOwner"] == "owner/repo")
            let message = input["message"] as! [String: String]
            precondition(message["headline"] == "Update screen-time: 2026-10-13 ~ 2026-10-14")
            precondition(message["body"] == "Add missing dates: 2026-10-13, 2026-10-14")
            let files = (input["fileChanges"] as! [String: Any])["additions"] as! [[String: String]]
            precondition(files[0]["path"] == "data/screen-time/2026.csv")
            let csv = String(data: Data(base64Encoded: files[0]["contents"]!)!, encoding: .utf8)!
            let rows = try CSV.parse(csv)
            precondition(rows.count == 3 && rows[1][0] == "2026-10-13")
            return try success()
        }
        try await client.push(directory: "screen-time", year: "2026", rows: [row("2026-10-14"), row("2026-10-13")])
        precondition(calls == 2)

        // A concurrent writer inserts one date. Retry must preserve its value.
        calls = 0
        MockProtocol.handler = { req in
            calls += 1
            let payload = try body(req)
            if calls == 1 { return try snapshot() }
            if calls == 2 { return try json(["errors": [["type": "STALE_DATA", "message": "Branch moved"]]]) }
            if calls == 3 { return try snapshot(CSV.encode([CSV.header, row("2026-10-14", "999")]), head: "head-2") }
            let input = (payload["variables"] as! [String: Any])["input"] as! [String: Any]
            precondition(input["expectedHeadOid"] as? String == "head-2")
            precondition((input["message"] as! [String: String])["headline"] == "Update screen-time: 2026-10-13")
            let file = ((input["fileChanges"] as! [String: Any])["additions"] as! [[String: String]])[0]
            let csv = String(data: Data(base64Encoded: file["contents"]!)!, encoding: .utf8)!
            precondition(tryRows(csv)[2][2] == "999")
            return try success()
        }
        try await client.push(directory: "screen-time", year: "2026", rows: [row("2026-10-14"), row("2026-10-13")])
        precondition(calls == 4)

        calls = 0
        MockProtocol.handler = { _ in calls += 1; return try snapshot(CSV.encode([CSV.header, row("2026-10-14", "999")])) }
        try await client.push(directory: "screen-time", year: "2026", rows: [row("2026-10-14")])
        precondition(calls == 1) // No mutation, even if the existing value differs.

        calls = 0
        MockProtocol.handler = { req in
            calls += 1
            let payload = try body(req)
            if calls == 1 {
                precondition((payload["variables"] as! [String: String])["path"] == "data/another-module/2026.csv")
                return try snapshot()
            }
            return try success()
        }
        try await client.push(directory: "another-module", year: "2026", rows: [row("2026-10-14")])
        precondition(calls == 2)

        MockProtocol.handler = { _ in fatalError("Invalid directory must not issue a request") }
        for directory in ["", ".", "..", "../other", "one/two", "one\\two"] {
            do { try await client.push(directory: directory, year: "2026", rows: [row("2026-10-14")]); fatalError("Accepted invalid directory") } catch is HakoError { }
        }
        for response: [String: Any] in [
            ["errors": [["type": "FORBIDDEN", "message": "Denied"]]],
            ["data": ["repository": NSNull()]],
            ["data": ["repository": ["ref": NSNull()]]]
        ] {
            MockProtocol.handler = { _ in try json(response) }
            do { try await client.push(directory: "screen-time", year: "2026", rows: [row("2026-10-14")]); fatalError("Accepted failed snapshot") } catch is HakoError { }
        }
        calls = 0
        MockProtocol.handler = { _ in
            calls += 1
            return calls % 2 == 1 ? try snapshot() : try json(["errors": [["type": "STALE_DATA", "message": "Branch moved"]]])
        }
        do { try await client.push(directory: "screen-time", year: "2026", rows: [row("2026-10-14")]); fatalError("Unlimited retry") } catch is HakoError { }
        precondition(calls == 6)
        calls = 0
        MockProtocol.handler = { _ in calls += 1; return calls == 1 ? try snapshot() : try success(signed: false) }
        do { try await client.push(directory: "screen-time", year: "2026", rows: [row("2026-10-14")]); fatalError("Accepted unverified signature") } catch let error as HakoError { precondition(error.message.contains("数据已提交")) }
        MockProtocol.handler = { _ in (401, Data()) }
        do { try await client.push(directory: "screen-time", year: "2026", rows: [row("2026-10-14")]); fatalError("Accepted 401") } catch is HakoError { }
        MockProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        do { try await client.push(directory: "screen-time", year: "2026", rows: [row("2026-10-14")]); fatalError("Accepted offline") } catch is URLError { }
        print("PASS: GraphQL signed commit payload/date messages/snapshot consistency/conflict merge/retry limit/no-op/signature failure/auth/offline/module paths")
    }
    static func tryRows(_ text: String) -> [[String]] { try! CSV.parse(text) }
}
