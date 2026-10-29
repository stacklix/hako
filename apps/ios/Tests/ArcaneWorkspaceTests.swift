import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class WorkspaceMockProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var handler: ((URLRequest) throws -> (Int, Data))?
    static func respond(_ block: @escaping (URLRequest) throws -> (Int, Data)) {
        lock.lock(); defer { lock.unlock() }; handler = block
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            Self.lock.lock()
            let result: Result<(Int, Data), Error>
            do { result = .success(try Self.handler!(request)) } catch { result = .failure(error) }
            Self.lock.unlock()
            let (status, data) = try result.get()
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

@main struct ArcaneWorkspaceTests {
    static func main() async throws {
        func bytes(_ text: String) -> Data { Data(text.utf8) }
        let decoder = JSONDecoder()
        let projectJSON = #"{"id":"p1","name":"app","path":"/projects/app","composeFileName":"compose.yaml","composeContent":"services: {}\n","envContent":"OLD=1\n"}"#
        let project = try decoder.decode(ArcaneProjectDocument.self, from: bytes(projectJSON))
        precondition(project.configurationFiles.map(\.relativePath) == ["compose.yaml", ".env"])
        precondition(project.editable(.compose) && project.content(.env) == "OLD=1\n")
        let git = try decoder.decode(ArcaneProjectDocument.self, from: bytes(#"{"id":"p1","name":"app","gitOpsManagedBy":"sync1"}"#))
        precondition(!git.editable(.compose) && git.editable(.env), "Git source files are read-only; effective env saves use Arcane's override handling")
        let archived = try decoder.decode(ArcaneProjectDocument.self, from: bytes(#"{"id":"p1","name":"app","isArchived":true}"#))
        precondition(!archived.editable(.compose) && !archived.editable(.env))
        let binary = try decoder.decode(ArcaneWorkspaceContent.self, from: bytes(#"{"relativePath":"logo.png","mimeType":"image/png","size":20,"editable":false,"readOnlyReason":"binary"}"#))
        precondition(!binary.viewable && binary.reasonText != nil)
        let readonly = try decoder.decode(ArcaneWorkspaceContent.self, from: bytes(#"{"relativePath":"config.txt","content":"source","mimeType":"text/plain","size":6,"editable":false,"readOnlyReason":"gitops_managed"}"#))
        precondition(readonly.viewable && !readonly.editable)
        for invalid in ["", "/etc/passwd", "../secret", "config/../secret", "a//b", "./.env", "a\\b", "bad\nname"] {
            do { try ArcaneWorkspacePath.validate(invalid); fatalError("Invalid workspace path accepted") }
            catch is ArcaneFailure { }
        }
        let path = "配置/conf #1.env"
        try ArcaneWorkspacePath.validate(path)
        precondition(ArcaneWorkspacePath.parent(path) == "配置" && ArcaneWorkspacePath.parent(".env") == "")
        let summaries = [ArcaneProjectSummary(id: "p1", name: "app", path: "/projects/a"),
                         ArcaneProjectSummary(id: "p2", name: "app", path: "/projects/b")]
        let resolved = try ArcaneProjectSummary.resolve(summaries, name: "app", workingDir: "/projects/b/")
        precondition(resolved.id == "p2")
        do { _ = try ArcaneProjectSummary.resolve(summaries, name: "app", workingDir: nil); fatalError("Ambiguous project accepted") }
        catch is ArcaneFailure { }
        let patch = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ArcaneProjectPatch(kind: .env, content: ""))) as! [String: Any]
        precondition(patch.count == 1 && patch["envContent"] as? String == "", "An empty env file is an explicit edit; unrelated fields stay omitted")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WorkspaceMockProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = try ArcaneClient(connection: ArcaneConnection(name: "test", address: "https://arcane.example.com/proxy", apiKey: "test-key"), session: session)
        let treeJSON = #"{"files":[{"name":"config.txt","relativePath":"nested/config.txt","size":3,"isDirectory":false,"isSymlink":false,"editable":true}],"fileTreeRevision":"r1","fileTreeTruncated":false}"#
        func envelope(_ text: String) -> Data { bytes("{\"success\":true,\"data\":\(text)}") }
        func failure(status: Int? = nil, unknown: Bool? = nil, _ block: () async throws -> Void) async {
            do { try await block(); fatalError("Expected workspace request failure") }
            catch let error as ArcaneFailure {
                if let status { precondition(error.status == status) }
                if let unknown { precondition(error.outcomeUnknown == unknown) }
            } catch { fatalError("Unexpected error: \(error)") }
        }
        WorkspaceMockProtocol.respond { request in
            precondition(request.value(forHTTPHeaderField: "X-Api-Key") == "test-key")
            precondition(request.url!.path == "/proxy/api/environments/remote/projects")
            return (200, envelope(#"[{"id":"p1","name":"app","path":"/projects/app"}]"#))
        }
        let projects = try await client.projects("remote")
        precondition(projects.first?.id == "p1")
        WorkspaceMockProtocol.respond { request in
            precondition(request.url!.path.hasSuffix("/p1/workspace"))
            return (200, envelope(treeJSON))
        }
        let tree = try await client.workspace("remote", project: "p1")
        precondition(tree.fileTreeRevision == "r1" && tree.files.first?.relativePath == "nested/config.txt")
        WorkspaceMockProtocol.respond { request in
            let parts = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            precondition(parts.queryItems == [URLQueryItem(name: "relativePath", value: path)])
            return (200, try JSONSerialization.data(withJSONObject: ["success": true, "data": ["relativePath": path, "content": "old\r\n", "mimeType": "text/plain", "size": 5, "editable": true]]))
        }
        let text = try await client.workspaceFile("remote", project: "p1", path: path)
        precondition(text.content == "old\r\n" && text.viewable)

        var writes = 0
        WorkspaceMockProtocol.respond { request in
            writes += 1
            precondition(request.httpMethod == "PUT" && request.url!.path.hasSuffix("/p1/workspace"))
            let type = request.value(forHTTPHeaderField: "Content-Type")!
            let boundary = String(type.split(separator: "=").last!)
            let body = String(data: readBody(request), encoding: .utf8)!
            let parts = body.components(separatedBy: "--" + boundary).filter { $0.contains("Content-Disposition:") }
            precondition(parts.count == 3 && parts[0].contains("name=\"manifest\"") && parts[1].contains("name=\"files\""))
            let manifestText = parts[0].components(separatedBy: "\r\n\r\n")[1]
            precondition(manifestText.hasSuffix("\r\n"))
            // CRLF is one Swift Character, but the multipart terminator is two bytes.
            let manifestData = Data(manifestText.utf8.dropLast(2))
            let manifest = try JSONSerialization.jsonObject(with: manifestData) as! [String: Any]
            let changes = manifest["fileChanges"] as! [[String: Any]]
            precondition(manifest["fileTreeRevision"] as? String == "r1")
            precondition(changes[0]["relativePath"] as? String == path && changes[0]["operation"] as? String == "update_file")
            precondition(changes[0]["uploadIndex"] as? Int == 0 && changes[0]["baselineIndex"] as? Int == 1)
            precondition(parts[1].hasSuffix("\r\n\r\nnew😀\n\r\n") && parts[2].hasSuffix("\r\n\r\nold\r\n\r\n"), "Both desired and exact baseline bytes must be uploaded")
            return (200, envelope(treeJSON))
        }
        _ = try await client.saveWorkspaceFile("remote", project: "p1", path: path, revision: "r1", baseline: "old\r\n", content: "new😀\n")
        precondition(writes == 1)
        await failure { _ = try await client.saveWorkspaceFile("remote", project: "p1", path: "../secret", revision: "r1", baseline: "", content: "new") }
        precondition(writes == 1)

        writes = 0
        WorkspaceMockProtocol.respond { request in
            if request.httpMethod == "GET" { return (200, envelope(projectJSON)) }
            writes += 1
            precondition(request.httpMethod == "PUT" && request.url!.path.hasSuffix("/projects/p1"))
            let body = try JSONSerialization.jsonObject(with: readBody(request)) as! [String: Any]
            precondition(body.count == 1 && body["envContent"] as? String == "NEW=2\n")
            return (200, envelope(projectJSON.replacingOccurrences(of: "OLD=1", with: "NEW=2")))
        }
        let saved = try await client.saveProjectFile("remote", project: "p1", kind: .env, baseline: "OLD=1\n", content: "NEW=2\n")
        precondition(saved.envContent == "NEW=2\n" && writes == 1)
        await failure(status: 409) { _ = try await client.saveProjectFile("remote", project: "p1", kind: .env, baseline: "changed elsewhere", content: "new") }
        precondition(writes == 1, "A changed configuration baseline must never be overwritten")
        for status in [403, 409, 500] {
            writes = 0
            WorkspaceMockProtocol.respond { _ in writes += 1; return (status, bytes("{}")) }
            await failure(status: status, unknown: status == 500) {
                _ = try await client.saveWorkspaceFile("remote", project: "p1", path: "file.txt", revision: "r1", baseline: "old", content: "new")
            }
            precondition(writes == 1, "File writes must never retry automatically")
        }
        WorkspaceMockProtocol.respond { _ in (200, bytes("{}")) }
        await failure(unknown: true) { _ = try await client.saveWorkspaceFile("remote", project: "p1", path: "file.txt", revision: "r1", baseline: "old", content: "new") }
        print("PASS: Arcane project resolution, file path isolation, binary/read-only metadata, multipart baselines, protected configuration patches, conflicts and write uncertainty/no retry")
    }

    private static func readBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var body = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: 4096)
            if count <= 0 { break }
            body.append(contentsOf: buffer.prefix(count))
        }
        return body
    }
}
