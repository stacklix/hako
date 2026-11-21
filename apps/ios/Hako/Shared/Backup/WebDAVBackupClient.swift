import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(FoundationXML)
import FoundationXML
#endif

@MainActor struct WebDAVBackupClient {
    typealias Send = (URLRequest) async throws -> (Data, HTTPURLResponse)
    let send: Send

    func check(settings: WebDAVBackupSettings, password: String) async throws {
        let url = try settings.baseURL()
        var request = try request(url: url, method: "PROPFIND", settings: settings, password: password)
        request.setValue("0", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("<?xml version=\"1.0\"?><d:propfind xmlns:d=\"DAV:\"><d:prop><d:resourcetype/></d:prop></d:propfind>".utf8)
        let (data, response) = try await send(request)
        let parser = DAVCollectionParser(expected: url)
        guard response.statusCode == 207, parser.isCollection(data) else {
            throw HakoBackupError(message: "无法访问 WebDAV 目录（HTTP \(response.statusCode)），请检查目录地址、用户名和密码。")
        }
    }

    func backup(data: Data, target: HakoBackupTarget, file: HakoBackupFile,
                mimeType: String, password: String, at date: Date) async throws -> String {
        let resolved = try file.resolved(at: date)
        let directories = try HakoBackupPath.components(target.parentDirectory) + resolved.directories
        var url = try target.webDAV.baseURL()
        for directory in directories {
            try Task.checkCancellation()
            url = url.appendingPathComponent(directory, isDirectory: true)
            let make = try request(url: url, method: "MKCOL", settings: target.webDAV, password: password)
            let (_, response) = try await send(make)
            // 405 can mean the collection exists. PUT and read-back must still succeed.
            guard response.statusCode == 201 || response.statusCode == 405 else {
                throw HakoBackupError(message: "WebDAV 无法创建备份目录（HTTP \(response.statusCode)）。")
            }
        }
        url = url.appendingPathComponent(resolved.fileName)
        var upload = try request(url: url, method: "PUT", settings: target.webDAV, password: password)
        upload.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        upload.httpBody = data
        let (_, response) = try await send(upload)
        guard [200, 201, 204].contains(response.statusCode) else {
            throw HakoBackupError(message: "WebDAV 上传失败（HTTP \(response.statusCode)）。")
        }
        let read = try request(url: url, method: "GET", settings: target.webDAV, password: password)
        let (downloaded, verification) = try await send(read)
        guard verification.statusCode == 200, downloaded == data else {
            throw HakoBackupError(message: "WebDAV 文件已上传，但下载回查与原文件不一致，请检查云端备份。")
        }
        return (directories + [resolved.fileName]).joined(separator: "/")
    }

    private func request(url: URL, method: String, settings: WebDAVBackupSettings, password: String) throws -> URLRequest {
        guard !settings.username.isEmpty, !settings.username.contains(":"), !password.isEmpty else {
            throw HakoBackupError(message: "请配置 WebDAV 用户名和密码；用户名不能包含冒号。")
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 180)
        request.httpMethod = method
        let authorization = Data("\(settings.username):\(password)".utf8).base64EncodedString()
        request.setValue("Basic \(authorization)", forHTTPHeaderField: "Authorization")
        return request
    }
}

private final class DAVCollectionParser: NSObject, XMLParserDelegate {
    private let expected: URL
    private var element = ""
    private var href = ""
    private var status = ""
    private var collection = false
    private var validProperty = false
    private var inProperty = false
    private var inResourceType = false
    private var found = false
    init(expected: URL) { self.expected = expected }

    func isCollection(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        return parser.parse() && found
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        guard namespaceURI == "DAV:" else { element = ""; return }
        element = name
        if name == "response" { href = ""; validProperty = false }
        if name == "propstat" { status = ""; collection = false; inProperty = true }
        if name == "resourcetype" { inResourceType = true }
        if name == "collection", inProperty && inResourceType { collection = true }
    }
    func parser(_ parser: XMLParser, foundCharacters text: String) {
        if element == "href" && !inProperty { href += text }
        if element == "status" && inProperty { status += text }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard namespaceURI == "DAV:" else { return }
        if name == "resourcetype" { inResourceType = false }
        if name == "propstat" {
            if status.split(separator: " ").dropFirst().first == "200", collection { validProperty = true }
            inProperty = false
        }
        if name == "response", validProperty,
           let url = URL(string: href.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: expected)?.absoluteURL,
           url.scheme == expected.scheme, url.host == expected.host, url.port == expected.port,
           url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == expected.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
            found = true
        }
        element = ""
    }
}
