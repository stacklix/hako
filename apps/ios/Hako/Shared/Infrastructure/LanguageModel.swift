import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum LanguageModelFormat: String, Codable, CaseIterable, Identifiable {
    case openAI, anthropic

    var id: Self { self }
    var title: String {
        switch self {
        case .openAI: "OpenAI 兼容 · Chat Completions"
        case .anthropic: "Anthropic 兼容 · Messages"
        }
    }
    var defaultURL: String {
        switch self {
        case .openAI: "https://api.openai.com/v1"
        case .anthropic: "https://api.anthropic.com/v1"
        }
    }
    var route: [String] { self == .openAI ? ["chat", "completions"] : ["messages"] }
}

struct LanguageModelConfiguration: Codable, Equatable {
    var format = LanguageModelFormat.openAI
    var baseURL = LanguageModelFormat.openAI.defaultURL
    var model = ""
    var token = ""

    func endpoint() throws -> URL {
        guard let components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.fragment == nil,
              components.query == nil, var url = components.url else {
            throw LanguageModelError.invalid("请填写有效的 HTTPS API 地址，地址中无需附加参数。")
        }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              token.utf8.allSatisfy({ (32...126).contains($0) }) else {
            throw LanguageModelError.invalid("请填写模型 ID 和有效的 API Token。")
        }
        let path = components.path.split(separator: "/")
        if path.suffix(format.route.count).map(String.init) != format.route {
            if path.isEmpty || (format == .anthropic && path.last != "v1") {
                url.appendPathComponent("v1")
            }
            for segment in format.route { url.appendPathComponent(segment) }
        }
        return url
    }
}

struct LanguageModelProfile: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = ""
    var configuration = LanguageModelConfiguration()
}

struct LanguageModelProfiles: Codable {
    private(set) var entries: [LanguageModelProfile] = []
    private(set) var selectedID: UUID?
    var active: LanguageModelProfile? { entries.first { $0.id == selectedID } ?? entries.first }

    private static let storage = SecureStorage.namespace("me.stackli.hako.language-model")
    private static let account = "profiles"

    @MainActor
    static func load(using storage: any SecretStorage = Self.storage) throws -> Self {
        guard let data = try storage.read(account: account) else { return Self() }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    mutating func upsert(_ profile: LanguageModelProfile) throws {
        var profile = profile
        profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !profile.name.isEmpty else { throw LanguageModelError.invalid("请填写配置名称。") }
        guard !entries.contains(where: { $0.id != profile.id && $0.name.caseInsensitiveCompare(profile.name) == .orderedSame }) else {
            throw LanguageModelError.invalid("这个配置名称已被使用，请换一个名称。")
        }
        _ = try profile.configuration.endpoint()
        if let index = entries.firstIndex(where: { $0.id == profile.id }) { entries[index] = profile }
        else { entries.append(profile) }
        selectedID = active?.id
    }

    mutating func select(_ id: UUID) throws {
        guard entries.contains(where: { $0.id == id }) else { throw LanguageModelError.invalid("这项模型配置已被删除。") }
        selectedID = id
    }

    mutating func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        selectedID = active?.id
    }

    @MainActor
    @discardableResult
    static func update(using storage: any SecretStorage = Self.storage, _ change: (inout Self) throws -> Void) throws -> Self {
        var profiles = try load(using: storage)
        try change(&profiles)
        try profiles.persist(using: storage)
        return profiles
    }

    private func persist(using storage: any SecretStorage) throws {
        try storage.save(JSONEncoder().encode(self), account: Self.account, accessibility: .whenUnlocked)
    }
}

enum LanguageModelError: LocalizedError {
    case invalid(String)
    case response(Int)
    case unreadable

    var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        case .response(401), .response(403): "模型服务拒绝了认证，请检查 API Token 和模型权限。"
        case .response(404): "找不到模型或 API 路径，请核对 API 格式、地址和模型 ID。"
        case .response(413): "模型服务拒绝了这次请求，请减少图片大小或新开对话。"
        case .response(429): "模型服务请求受限，请稍后重试。"
        case .response(let code): "模型请求失败（HTTP \(code)）。"
        case .unreadable: "模型返回的内容无法读取，请检查 API 兼容格式。"
        }
    }
}

struct LanguageModelTool {
    let name: String
    let description: String
    let properties: [String: [String: Any]]
    let required: [String]

    func definition(for format: LanguageModelFormat) -> [String: Any] {
        let schema: [String: Any] = ["type": "object", "properties": properties, "required": required,
                                     "additionalProperties": false]
        switch format {
        case .openAI:
            return ["type": "function", "function": ["name": name, "description": description, "parameters": schema]]
        case .anthropic:
            return ["name": name, "description": description, "input_schema": schema]
        }
    }
}

struct LanguageModelCall {
    let id: String
    let name: String
    let arguments: [String: Any]?
}

struct LanguageModelReply {
    let message: [String: Any]
    let text: String
    let calls: [LanguageModelCall]
}

struct LanguageModelClient {
    private static let session = HTTPTransport.makeSession(requestTimeout: 90, resourceTimeout: 180)
    let configuration: LanguageModelConfiguration

    func userMessage(_ text: String, images: [Data] = []) -> [String: Any] {
        if configuration.format == .openAI, images.isEmpty { return ["role": "user", "content": text] }
        var parts: [[String: Any]] = []
        if !text.isEmpty { parts.append(["type": "text", "text": text]) }
        for image in images {
            let data = image.base64EncodedString()
            switch configuration.format {
            case .openAI: parts.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + data]])
            case .anthropic: parts.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": data]])
            }
        }
        return ["role": "user", "content": parts]
    }

    func toolMessages(_ results: [(LanguageModelCall, String)]) -> [[String: Any]] {
        switch configuration.format {
        case .openAI:
            return results.map { ["role": "tool", "tool_call_id": $0.0.id, "content": $0.1] }
        case .anthropic:
            let content = results.map { ["type": "tool_result", "tool_use_id": $0.0.id, "content": $0.1] }
            return [["role": "user", "content": content]]
        }
    }

    func request(system: String, messages: [[String: Any]], tools: [LanguageModelTool]) throws -> URLRequest {
        var request = URLRequest(url: try configuration.endpoint())
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let token = configuration.token.trimmingCharacters(in: .whitespacesAndNewlines)
        var body: [String: Any] = ["model": configuration.model.trimmingCharacters(in: .whitespacesAndNewlines), "stream": false]
        let definitions = tools.map { $0.definition(for: configuration.format) }
        if !definitions.isEmpty { body["tools"] = definitions }
        switch configuration.format {
        case .openAI:
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            body["messages"] = [["role": "system", "content": system]] + messages
        case .anthropic:
            request.setValue(token, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body["system"] = system
            body["messages"] = messages
            body["max_tokens"] = 4096
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func complete(system: String, messages: [[String: Any]], tools: [LanguageModelTool] = []) async throws -> LanguageModelReply {
        let request = try request(system: system, messages: messages, tools: tools)
        // Use the shared no-redirect policy without recording chat, images, or response headers.
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LanguageModelError.unreadable }
        guard (200..<300).contains(http.statusCode) else { throw LanguageModelError.response(http.statusCode) }
        return try decode(data)
    }

    func decode(_ data: Data) throws -> LanguageModelReply {
        guard let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw LanguageModelError.unreadable
        }
        switch configuration.format {
        case .openAI:
            guard let choices = body["choices"] as? [[String: Any]], let choice = choices.first,
                  let message = choice["message"] as? [String: Any] else { throw LanguageModelError.unreadable }
            let calls = try (message["tool_calls"] as? [[String: Any]] ?? []).map { call in
                guard let id = call["id"] as? String, let function = call["function"] as? [String: Any],
                      let name = function["name"] as? String else { throw LanguageModelError.unreadable }
                let args = (function["arguments"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
                return LanguageModelCall(id: id, name: name, arguments: args as? [String: Any])
            }
            var continuation: [String: Any] = ["role": "assistant", "content": message["content"] ?? NSNull()]
            if !calls.isEmpty { continuation["tool_calls"] = message["tool_calls"] }
            if let reasoning = message["reasoning_content"] as? String { continuation["reasoning_content"] = reasoning }
            let text = message["content"] as? String ?? message["refusal"] as? String ?? ""
            if calls.isEmpty, message["content"] as? String == nil { continuation["content"] = text }
            return LanguageModelReply(message: continuation, text: text, calls: calls)
        case .anthropic:
            guard let parts = body["content"] as? [[String: Any]] else { throw LanguageModelError.unreadable }
            let calls = try parts.filter { $0["type"] as? String == "tool_use" }.map { part in
                guard let id = part["id"] as? String, let name = part["name"] as? String else {
                    throw LanguageModelError.unreadable
                }
                return LanguageModelCall(id: id, name: name, arguments: part["input"] as? [String: Any])
            }
            let text = parts.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
            return LanguageModelReply(message: ["role": "assistant", "content": parts], text: text, calls: calls)
        }
    }
}
