import Foundation
import SwiftData

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
    @MainActor static func main() async throws {
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
        func directory(_ entries: [[String: String]]? = nil) throws -> (Int, Data) {
            let file: Any = entries.map { ["object": ["entries": $0]] as [String: Any] } ?? NSNull()
            return try json(["data": ["repository": ["ref": ["target": ["oid": "head-1", "file": file]]]]])
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
        let initialRows = try await client.push(directory: "screen-time", year: "2026", rows: [row("2026-10-14"), row("2026-10-13")])
        precondition(initialRows.count == 2)
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
        let concurrentRows = try await client.push(directory: "screen-time", year: "2026", rows: [row("2026-10-14"), row("2026-10-13")])
        precondition(concurrentRows[1][2] == "999") // Import the final retry, not the stale snapshot.
        precondition(calls == 4)

        calls = 0
        MockProtocol.handler = { _ in calls += 1; return try snapshot(CSV.encode([CSV.header, row("2026-10-14", "999")])) }
        let unchangedRows = try await client.push(directory: "screen-time", year: "2026", rows: [row("2026-10-14")])
        precondition(unchangedRows == [row("2026-10-14", "999")])
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

        // Discover remote-only years while ignoring files from other formats and subdirectories.
        MockProtocol.handler = { req in
            let payload = try body(req)
            precondition((payload["query"] as! String).contains("query HakoYears"))
            let variables = payload["variables"] as! [String: String]
            precondition(variables["ref"] == "refs/heads/data/main" && variables["path"] == "data/screen-time")
            return try directory([
                ["name": "2026.csv", "type": "blob"], ["name": "2024.csv", "type": "blob"],
                ["name": "README.md", "type": "blob"], ["name": "2025.csv", "type": "tree"],
                ["name": "bad.csv", "type": "blob"]
            ])
        }
        let remoteYears = try await client.years(directory: "screen-time")
        precondition(remoteYears == ["2024", "2026"])
        MockProtocol.handler = { _ in try directory() }
        let missingDirectory = try await client.years(directory: "screen-time")
        precondition(missingDirectory.isEmpty)
        for response: [String: Any] in [
            ["errors": [["type": "FORBIDDEN", "message": "Denied"]]],
            ["data": ["repository": ["ref": NSNull()]]],
            ["data": ["repository": ["ref": ["target": ["oid": "head-1", "file": ["object": [:]]]]]]]
        ] {
            MockProtocol.handler = { _ in try json(response) }
            do { _ = try await client.years(directory: "screen-time"); fatalError("Accepted invalid directory snapshot") } catch is HakoError { }
        }

        // Exercise the same database/network orchestration used by the merge button.
        let container = try ModelContainer(for: DailyUsage.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        var archivedApp = row("2026-10-14", "999")
        archivedApp[3] = "com.example.app"; archivedApp[4] = "99"
        var remoteFiles = [
            "2024": CSV.encode([CSV.header, row("2024-01-01")]),
            "2026": CSV.encode([CSV.header, archivedApp])
        ]
        var mutations = 0
        MockProtocol.handler = { req in
            let payload = try body(req), variables = payload["variables"] as! [String: Any]
            let query = payload["query"] as! String
            if query.contains("query HakoYears") {
                return try directory(remoteFiles.keys.map { ["name": $0 + ".csv", "type": "blob"] })
            }
            if query.contains("query HakoSnapshot") {
                let path = variables["path"] as! String
                let year = String(path.split(separator: "/").last!.prefix(4))
                return try snapshot(remoteFiles[year])
            }
            let input = variables["input"] as! [String: Any]
            let file = ((input["fileChanges"] as! [String: Any])["additions"] as! [[String: String]])[0]
            let year = String(file["path"]!.split(separator: "/").last!.prefix(4))
            remoteFiles[year] = String(data: Data(base64Encoded: file["contents"]!)!, encoding: .utf8)!
            mutations += 1
            return try success()
        }
        let restored = try await UsageSync.merge(context: context, client: client, directory: "screen-time")
        precondition(restored.inserted == 2 && restored.days == 2 && mutations == 0)
        let recovered = try ModelContext(container).fetch(FetchDescriptor<DailyUsage>())
        precondition(recovered.count == 2 && recovered.allSatisfy { $0.syncedAt != nil })

        let local = try context.fetch(FetchDescriptor<DailyUsage>()).first { $0.day == "2026-10-14" }!
        local.totalSeconds = 10
        local.appsData = try JSONEncoder().encode([AppUsage(bundleID: "com.example.app", name: "本地名称", seconds: 1, applicationTokenData: Data([1, 2]))])
        for day in ["2025-12-31", "2026-10-15"] {
            context.insert(try DailyUsage(day: day, timeZone: "Asia/Shanghai", totalSeconds: 120, apps: []))
        }
        try context.save()
        remoteFiles["2026"] = CSV.encode([CSV.header, row("2026-10-13"), archivedApp])
        let union = try await UsageSync.merge(context: context, client: client, directory: "screen-time")
        precondition(union.inserted == 1 && union.updated == 1 && union.days == 5 && mutations == 2)
        precondition(local.totalSeconds == 999 && local.apps[0].seconds == 99)
        precondition(local.apps[0].name == "本地名称" && local.apps[0].applicationTokenData == Data([1, 2]))
        let persisted = try ModelContext(container).fetch(FetchDescriptor<DailyUsage>())
        precondition(persisted.count == 5 && persisted.allSatisfy { $0.syncedAt != nil })
        precondition(tryRows(remoteFiles["2025"]!)[1][0] == "2025-12-31")
        precondition(tryRows(remoteFiles["2026"]!).map { $0[0] } == ["date", "2026-10-13", "2026-10-14", "2026-10-15"])
        let repeatMerge = try await UsageSync.merge(context: context, client: client, directory: "screen-time")
        precondition(repeatMerge.inserted == 0 && repeatMerge.updated == 0 && repeatMerge.days == 5 && mutations == 2)

        // Invalid remote values and network failures leave the saved local data intact.
        remoteFiles["2026"] = CSV.encode([CSV.header, row("2026-10-14", "NaN")])
        do { _ = try await UsageSync.merge(context: context, client: client, directory: "screen-time"); fatalError("Imported invalid seconds") } catch is HakoError { }
        precondition(local.totalSeconds == 999 && mutations == 2)
        MockProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        do { _ = try await UsageSync.merge(context: context, client: client, directory: "screen-time"); fatalError("Accepted offline merge") } catch is URLError { }
        let afterFailure = try ModelContext(container).fetch(FetchDescriptor<DailyUsage>())
        precondition(afterFailure.count == 5)

        let emptyContainer = try ModelContainer(for: DailyUsage.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        MockProtocol.handler = { _ in try directory() }
        let empty = try await UsageSync.merge(context: ModelContext(emptyContainer), client: client, directory: "screen-time")
        precondition(empty.days == 0 && empty.inserted == 0)

        let builds = BuildStatusClient(session: URLSession(configuration: config), token: "test-token")
        calls = 0
        MockProtocol.handler = { req in
            calls += 1
            precondition(req.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
            if calls == 1 {
                precondition(req.url!.path == "/repos/stacklix/hako/actions/workflows/ios.yml/runs")
                precondition(req.url!.query == "branch=master&per_page=1")
                return try json(["workflow_runs": [["id": 123, "run_number": 42, "run_attempt": 2,
                    "status": "in_progress", "updated_at": "2026-10-22T08:30:00Z"]]])
            }
            precondition(req.url!.path == "/repos/stacklix/hako/actions/runs/123/attempts/2/jobs")
            return try json(["jobs": [["id": 456, "name": "build", "status": "in_progress",
                "steps": [["name": "Archive and export signed IPA", "status": "in_progress"]]]]])
        }
        let progress = try await builds.latest()
        precondition(calls == 2 && progress?.run.runNumber == 42)
        precondition(progress?.run.refreshInterval == 5)
        for status in ["queued", "waiting", "in_progress", "completed"] {
            let run = BuildStatusClient.Run(id: 123, runNumber: 42, runAttempt: 1,
                                           status: status, conclusion: nil, updatedAt: .now)
            precondition(run.refreshInterval == (status == "completed" ? 30 : 5))
        }
        for conclusion in ["success", "failure", "cancelled"] {
            let run = BuildStatusClient.Run(id: 123, runNumber: 42, runAttempt: 1,
                                           status: "completed", conclusion: conclusion, updatedAt: .now)
            precondition(run.refreshInterval == 30)
        }
        precondition(progress?.jobs.first?.activeStep == "Archive and export signed IPA")
        precondition(BuildStatusClient.statusText("completed", conclusion: "failure") == "失败")
        precondition(BuildStatusClient.statusText("completed", conclusion: "cancelled") == "已取消")
        calls = 0
        MockProtocol.handler = { _ in calls += 1; return try json(["workflow_runs": []]) }
        let emptyBuild = try await builds.latest()
        precondition(emptyBuild == nil && calls == 1)
        for status in [401, 403, 404, 429, 500] {
            MockProtocol.handler = { _ in (status, Data()) }
            do { _ = try await builds.latest(); fatalError("Accepted failed build status request") }
            catch is HakoError { }
        }
        print("PASS: GitHub sync; empty-local restore/multi-year union/conflicts/metadata/idempotency/failures; build status")
    }
    static func tryRows(_ text: String) -> [[String]] { try! CSV.parse(text) }
}
