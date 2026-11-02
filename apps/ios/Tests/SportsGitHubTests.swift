import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class SportsMockProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, data) = try Self.handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

@main struct SportsGitHubTests {
    static func main() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SportsMockProtocol.self]
        let client = SportsGitHub(repository: GitHubService(settings: GitHubSettings(repositoryURL: "https://github.com/owner/repo", branch: "master"), tokenProvider: { "test-token" }, session: URLSession(configuration: config)))
        let record = SportsRecord(id: UUID(), date: "20260101", type: "Swimming", distance: 1.05, duration: 69)
        func json(_ object: [String: Any]) throws -> (Int, Data) { (200, try JSONSerialization.data(withJSONObject: object)) }
        func body(_ request: URLRequest) throws -> [String: Any] {
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count == 0 { break }
                    guard count > 0 else { throw SportsError(message: "Cannot read request") }
                    data.append(contentsOf: buffer.prefix(count))
                }
            }
            return try JSONSerialization.jsonObject(with: data) as! [String: Any]
        }
        var calls = 0
        SportsMockProtocol.handler = { request in
            calls += 1
            let payload = try body(request), vars = payload["variables"] as! [String: Any]
            if (payload["query"] as! String).contains("HakoDirectory") {
                precondition(vars["path"] as? String == "data/sports")
                precondition(vars["ref"] as? String == "refs/heads/master")
                return try json(["data": ["repository": ["ref": ["target": ["oid": "pinned-head", "file": ["object": ["entries": [["name": "2026.csv", "type": "blob"], ["name": "ignore.txt", "type": "blob"]]]]]]]]])
            }
            precondition(vars["oid"] as? String == "pinned-head")
            precondition((payload["query"] as! String).contains("history(first: 1, path: $path)"))
            let path = vars["path"] as! String
            let file: Any = path.contains("2026") ? ["object": ["text": SportsCSV.encode([record]), "isBinary": false, "isTruncated": false]] : NSNull()
            // Also return history for a remotely deleted annual file.
            return try json(["data": ["repository": ["object": ["oid": "pinned-head", "file": file, "history": ["nodes": [["committedDate": "2026-01-02T03:04:05Z"]]]]]]])
        }
        let remote = try await client.sportsPull(localYears: ["2025"])
        precondition(calls == 3 && remote.records == [record])
        precondition(remote.existingYears == ["2026"] && remote.modifiedAt.count == 2)
        precondition(remote.head == "pinned-head")

        var writes = 0
        SportsMockProtocol.handler = { request in
            writes += 1
            let vars = try body(request)["variables"] as! [String: Any]
            let input = vars["input"] as! [String: Any]
            precondition(input["expectedHeadOid"] as? String == "pinned-head")
            let additions = (input["fileChanges"] as! [String: Any])["additions"] as! [[String: String]]
            precondition(additions.count == 2)
            precondition(Set(additions.compactMap { $0["path"] }) == ["data/sports/2025.csv", "data/sports/2026.csv"])
            return try json(["data": ["createCommitOnBranch": ["commit": ["oid": "signed", "signature": ["isValid": true, "wasSignedByGitHub": true]]]]])
        }
        let files = ["data/sports/2025.csv": SportsCSV.encode([]), "data/sports/2026.csv": SportsCSV.encode([record])]
        let committed = try await client.sportsCommit(files: files, head: remote.head)
        precondition(committed && writes == 1)
        let unchanged = try await client.sportsCommit(files: [:], head: remote.head)
        precondition(unchanged && writes == 1)

        SportsMockProtocol.handler = { _ in try json(["errors": [["type": "STALE_DATA", "message": "Head moved"]]]) }
        let stale = try await client.sportsCommit(files: files, head: remote.head)
        precondition(!stale)

        SportsMockProtocol.handler = { _ in (500, Data()) }
        do { _ = try await client.sportsPull(localYears: []); fatalError("Accepted failed read") } catch is HakoError { }
        do { _ = try await client.sportsCommit(files: files, head: remote.head); fatalError("Accepted failed upload") } catch is HakoError { }
        SportsMockProtocol.handler = { _ in throw URLError(.timedOut) }
        do { _ = try await client.sportsCommit(files: files, head: remote.head); fatalError("Accepted uncertain write") } catch is URLError { }

        SportsMockProtocol.handler = { _ in try json(["data": ["createCommitOnBranch": ["commit": ["oid": "unsigned", "signature": ["isValid": false, "wasSignedByGitHub": false]]]]]) }
        do { _ = try await client.sportsCommit(files: files, head: remote.head); fatalError("Accepted unsigned commit") } catch is HakoError { }
        print("Sports GitHub tests passed: pinned snapshots, per-file history, atomic signed commits, stale heads and failures")
    }
}
