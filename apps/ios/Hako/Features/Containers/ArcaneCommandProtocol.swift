import Foundation

enum ArcaneCommandParameterKind: String, Codable, CaseIterable, Identifiable {
    case text, number, choice, toggle, password
    var id: String { rawValue }
    var title: String {
        switch self {
        case .text: return "文本"
        case .number: return "数字"
        case .choice: return "选项"
        case .toggle: return "开关"
        case .password: return "密码"
        }
    }
}

struct ArcaneCommandParameter: Codable, Equatable, Identifiable {
    var key: String
    var name: String
    var kind: ArcaneCommandParameterKind = .text
    var defaultValue = ""
    var required = true
    var choices: [String] = []
    var id: String { key }
}

struct ArcaneCommandDefinition: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var name = ""
    var template = ""
    var confirmation = false
    var parameters: [ArcaneCommandParameter] = []
    var builtIn = false

    static func keys(in template: String) throws -> [String] {
        guard template.utf8.count <= 4096, !template.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw ArcaneFailure(message: "命令模板过长或包含无效字符。")
        }
        let regex = try NSRegularExpression(pattern: #"\{\{([^{}]*)\}\}"#)
        let text = template as NSString
        let matches = regex.matches(in: template, range: NSRange(location: 0, length: text.length))
        var keys: [String] = []
        for match in matches {
            let key = text.substring(with: match.range(at: 1))
            guard key.range(of: #"^[A-Za-z][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else {
                throw ArcaneFailure(message: "参数标识须以字母开头，只能包含字母、数字和下划线。")
            }
            if !keys.contains(key) { keys.append(key) }
        }
        let remainder = regex.stringByReplacingMatches(in: template, range: NSRange(location: 0, length: text.length), withTemplate: "")
        guard !remainder.contains("{{"), !remainder.contains("}}"), keys.count <= 24 else {
            throw ArcaneFailure(message: "请补全 {{参数标识}}；每项操作最多支持 24 个参数。")
        }
        if !keys.isEmpty { try checkPlacement(template) }
        return keys
    }

    private static func checkPlacement(_ template: String) throws {
        guard !template.contains("<<"), !template.contains("`") else {
            throw ArcaneFailure(message: "带参数的模板暂不支持 here-document 或反引号，请使用容器终端执行。")
        }
        let chars = Array(template)
        var index = 0, quote: Character?, escaped = false
        while index < chars.count {
            let c = chars[index]
            if index + 1 < chars.count, c == "{", chars[index + 1] == "{" {
                var end = index + 2
                while end + 1 < chars.count && !(chars[end] == "}" && chars[end + 1] == "}") { end += 1 }
                let before = index == 0 || chars[index - 1].isWhitespace || "=;|&(".contains(chars[index - 1])
                let after = end + 2 == chars.count || chars[end + 2].isWhitespace || ";|&)".contains(chars[end + 2])
                guard quote == nil, !escaped, before, after else {
                    throw ArcaneFailure(message: "{{参数标识}} 须独立使用（或跟在 --选项= 后），不要加引号或拼接其他文字。")
                }
                index = end + 2; continue
            }
            if escaped { escaped = false }
            else if c == "\\" && quote != "'" { escaped = true }
            else if let current = quote { if c == current { quote = nil } }
            else if c == "'" || c == "\"" { quote = c }
            index += 1
        }
    }

    static func inferred(_ key: String, template: String) -> ArcaneCommandParameter {
        let names = ["config": "配置文件", "adapter": "配置格式", "address": "管理地址", "port": "端口", "timeout": "超时时间", "count": "次数", "limit": "数量上限", "username": "用户名", "password": "密码", "token": "令牌"]
        var value = ArcaneCommandParameter(key: key, name: names[key.lowercased()] ?? key)
        let lower = key.lowercased()
        if ["password", "passwd", "token", "secret", "api_key"].contains(where: lower.contains) { value.kind = .password }
        else if ["port", "timeout", "count", "limit", "retries"].contains(lower) { value.kind = .number }
        if template.range(of: #"\bcaddy\s+(reload|validate)\b"#, options: .regularExpression) != nil {
            if lower == "config" { value.defaultValue = "/etc/caddy/Caddyfile" }
            if lower == "adapter" { value.kind = .choice; value.defaultValue = "caddyfile"; value.choices = ["caddyfile"] }
            if lower == "address" { value.defaultValue = "localhost:2019" }
        }
        return value
    }

    func validated() throws -> Self {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80,
              !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ArcaneFailure(message: "请填写操作名称和命令模板。") }
        let keys = try Self.keys(in: template)
        guard parameters.map(\.key) == keys else { throw ArcaneFailure(message: "参数列表须与命令模板保持一致。") }
        var value = self
        for index in value.parameters.indices {
            var p = value.parameters[index]
            guard !p.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, p.name.count <= 80 else { throw ArcaneFailure(message: "请填写参数名称。") }
            if p.kind == .password { p.defaultValue = "" }
            if p.kind == .choice {
                guard !p.choices.isEmpty, p.choices.count <= 40, p.choices.contains(p.defaultValue) else { throw ArcaneFailure(message: "\(p.name)需要选项，默认值须属于选项。") }
            }
            if p.kind == .number, !p.defaultValue.isEmpty { try Self.checkNumber(p.defaultValue, name: p.name) }
            if p.kind == .toggle, !["true", "false"].contains(p.defaultValue) { throw ArcaneFailure(message: "开关默认值须为 true 或 false。") }
            value.parameters[index] = p
        }
        return value
    }

    func resolve(_ values: [String: String], preview: Bool = false) throws -> String {
        let definition = try validated()
        let regex = try NSRegularExpression(pattern: #"\{\{([A-Za-z][A-Za-z0-9_]*)\}\}"#)
        // JSON is Caddy's native format, not an adapter named "json".
        let nativeJSON = builtIn && ["caddy.validate", "caddy.reload"].contains(id) && (values["adapter"] ?? parameters.first(where: { $0.key == "adapter" })?.defaultValue) == "json"
        let base = nativeJSON ? template.replacingOccurrences(of: " --adapter {{adapter}}", with: "") : template
        let original = base as NSString
        var output = base
        for match in regex.matches(in: base, range: NSRange(location: 0, length: original.length)).reversed() {
            let key = original.substring(with: match.range(at: 1))
            let p = definition.parameters.first { $0.key == key }!
            let raw = values[key] ?? p.defaultValue
            guard !raw.unicodeScalars.contains(where: { $0.value == 0 }), raw.utf8.count <= 4096 else { throw ArcaneFailure(message: "\(p.name)过长或包含无效字符。") }
            if !preview {
                if p.required && raw.isEmpty && p.kind != .toggle { throw ArcaneFailure(message: "请填写\(p.name)。") }
                if p.kind == .number && !raw.isEmpty { try Self.checkNumber(raw, name: p.name) }
                if p.kind == .choice && !p.choices.contains(raw) { throw ArcaneFailure(message: "请选择\(p.name)。") }
                if p.kind == .toggle && !["true", "false"].contains(raw) { throw ArcaneFailure(message: "\(p.name)的开关值无效。") }
            }
            let replacement = Self.quote(p.kind == .password && preview ? "[已隐藏]" : raw)
            let range = Range(match.range, in: output)!
            output.replaceSubrange(range, with: replacement)
        }
        return output
    }

    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func checkNumber(_ value: String, name: String) throws {
        guard let number = Double(value), number.isFinite else { throw ArcaneFailure(message: "\(name)必须是有效数字。") }
    }
    static var caddy: [Self] {
        [("caddy.validate", "配置检查", "caddy validate --config {{config}} --adapter {{adapter}}", false),
         ("caddy.reload", "重载配置", "caddy reload --config {{config}} --adapter {{adapter}} --address {{address}}", true)].map { id, name, template, confirmation in
            var parameters = (try! keys(in: template)).map { inferred($0, template: template) }
            if let index = parameters.firstIndex(where: { $0.key == "adapter" }) { parameters[index].choices = ["caddyfile", "json"] }
            return Self(id: id, name: name, template: template, confirmation: confirmation, parameters: parameters, builtIn: true)
        }
    }
}

struct ArcaneCommandContext: Codable, Hashable {
    let connection: String
    let environment: String
    let owner: [String]
    init(connection: String, environment: String, details: ArcaneContainerDetails) {
        self.connection = connection; self.environment = environment
        if let project = details.project, let service = details.labels?["com.docker.compose.service"], !service.isEmpty {
            owner = ["compose", project, service]
        } else { owner = ["container", details.displayName] }
    }
    // JSON objects don't have a stable key order. Encode a positional array for storage.
    var stableKey: String { "arcane.commands." + (try! JSONEncoder().encode([connection, environment] + owner)).base64EncodedString() }
}

enum ArcaneCommandRedaction {
    static func text(_ value: String, secrets: [String], partialSuffix: Bool = true) -> String {
        var text = value
        for secret in secrets.filter({ !$0.isEmpty }).sorted(by: { $0.count > $1.count }) {
            text = text.replacingOccurrences(of: secret, with: "[已隐藏]")
            if partialSuffix && secret.count > 1 {
                let maxLength = min(secret.count - 1, text.count)
                if maxLength > 0 {
                    for count in stride(from: maxLength, through: 1, by: -1) where text.hasSuffix(String(secret.prefix(count))) {
                        text.removeLast(count); text += "[已隐藏]"; break
                    }
                }
            }
        }
        return text
    }
}
