import Foundation

// UTF-16 ranges match NSTextStorage, including emoji and non-ASCII paths/values.
enum ArcaneSyntax {
    enum Language: String, Sendable { case yaml = "YAML", env = "ENV", json = "JSON", toml = "TOML / INI", shell = "Shell", config = "配置", plain = "文本" }
    enum Kind: String, Sendable { case string, comment, key, literal, number, variable }
    struct Token: Sendable { let range: NSRange; let kind: Kind }

    static func language(filename: String) -> Language {
        let name = filename.lowercased().split(separator: "/").last.map(String.init) ?? filename.lowercased()
        if name == ".env" || name.hasPrefix(".env.") || name.hasSuffix(".env") { return .env }
        switch (name as NSString).pathExtension {
        case "yml", "yaml": return .yaml
        case "json", "jsonc": return .json
        case "toml", "ini", "properties": return .toml
        case "sh", "bash", "zsh": return .shell
        case "conf", "cfg": return .config
        default: return name == "dockerfile" ? .shell : .plain
        }
    }

    static func tokens(_ text: String, language: Language) -> [Token] {
        guard language != .plain else { return [] }
        let comments: String
        switch language {
        case .json: comments = #"//[^\r\n]*|/\*[\s\S]*?\*/"#
        case .toml: comments = #"(?<!\S)[#;][^\r\n]*"#
        default: comments = #"(?<!\S)#[^\r\n]*"#
        }
        let pattern = #"(?<string>"(?:\\[\s\S]|[^"\\])*"|'(?:''|[^'])*')|(?<comment>"# + comments
            + #")|(?<variable>\$\{[^}\r\n]*\}|\$[A-Za-z_][A-Za-z_0-9]*)|(?<key>[\p{L}_][\p{L}\p{N}_./-]*(?=[ \t]*[:=]))|(?<literal>\b(?:true|false|null|yes|no|on|off|export)\b)|(?<number>(?<![\p{L}\p{N}_./:-])-?(?:0x[0-9a-fA-F]+|[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)(?![\p{L}\p{N}_./:-]))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let source = text as NSString
        let kinds: [Kind] = [.string, .comment, .variable, .key, .literal, .number]
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).compactMap { match in
            for kind in kinds {
                let range = match.range(withName: kind.rawValue)
                guard range.location != NSNotFound else { continue }
                if kind == .string {
                    var next = NSMaxRange(range)
                    while next < source.length, [9, 32].contains(source.character(at: next)) { next += 1 }
                    return Token(range: range, kind: next < source.length && source.character(at: next) == 58 ? .key : .string)
                }
                return Token(range: range, kind: kind)
            }
            return nil
        }
    }
}
