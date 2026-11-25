import Foundation

// UTF-16 ranges match NSTextStorage, including emoji and non-ASCII paths/values.
enum HakoCodeSyntax {
    enum Language: String, Sendable { case yaml = "YAML", env = "ENV", json = "JSON", toml = "TOML / INI", shell = "Shell", python = "Python", config = "配置", plain = "文本" }
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
        case "py", "pyw", "pyi": return .python
        case "conf", "cfg": return .config
        default: return name == "dockerfile" ? .shell : .plain
        }
    }

    static func tokens(_ text: String, language: Language) -> [Token] {
        guard language != .plain else { return [] }
        if language == .python { return pythonTokens(text) }
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

    private static let pythonKeywords: Set<String> = [
        "False", "None", "True", "and", "as", "assert", "async", "await", "break", "class", "continue",
        "def", "del", "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "in",
        "is", "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield"
    ]
    private static let pythonBuiltins: Set<String> = [
        "abs", "all", "any", "bool", "bytearray", "bytes", "callable", "chr", "classmethod", "dict", "dir",
        "enumerate", "Exception", "filter", "float", "format", "frozenset", "getattr", "hasattr", "hash",
        "hex", "id", "input", "int", "isinstance", "issubclass", "iter", "len", "list", "map", "max",
        "min", "next", "object", "open", "ord", "pow", "print", "property", "range", "repr", "reversed",
        "round", "set", "setattr", "slice", "sorted", "staticmethod", "str", "sum", "super", "tuple",
        "type", "ValueError", "TypeError", "RuntimeError", "KeyError", "IndexError", "StopIteration", "zip"
    ]
    private static let pythonExpression: NSRegularExpression? = {
        // Strings/comments are consumed as complete tokens before scanning their contents.
        // Unfinished strings keep their color while typing; ordinary quotes stop at EOL.
        let string = #"(?:(?<![\p{L}\p{N}_])(?i:br|rb|fr|rf|r|u|b|f))?(?:"""(?:\\[\s\S]|(?!""")[^\\])*(?:"""|\z)|'''(?:\\[\s\S]|(?!''')[^\\])*(?:'''|\z)|"(?:\\[\s\S]|[^"\\\r\n])*(?:"|(?=[\r\n]|\z))|'(?:\\[\s\S]|[^'\\\r\n])*(?:'|(?=[\r\n]|\z)))"#
        let number = #"(?<![\p{L}\p{N}_])(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|(?:[0-9][0-9_]*(?:\.[0-9_]*)?|\.[0-9][0-9_]*)(?:[eE][+-]?[0-9][0-9_]*)?)[jJ]?(?![\p{L}\p{N}_])"#
        let identifier = #"[\p{L}_][\p{L}\p{N}\p{M}_]*"#
        let pattern = "(?<string>" + string + #")|(?<comment>#[^\r\n]*)|(?<number>"# + number
            + ")|(?m:^[ \t]*(?<variable>@" + identifier + "(?:\\." + identifier + ")*))|(?<identifier>" + identifier + ")"
        return try? NSRegularExpression(pattern: pattern)
    }()

    private static func pythonTokens(_ text: String) -> [Token] {
        guard let regex = pythonExpression else { return [] }
        let source = text as NSString
        var expectsName = false
        var previousEnd = 0
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).compactMap { match in
            let gap = source.substring(with: NSRange(location: previousEnd, length: match.range.location - previousEnd))
            let declarationName = expectsName && gap.allSatisfy { $0 == " " || $0 == "\t" }
            previousEnd = NSMaxRange(match.range)
            expectsName = false
            for kind in [Kind.string, .comment, .number, .variable] {
                let range = match.range(withName: kind.rawValue)
                if range.location != NSNotFound { return Token(range: range, kind: kind) }
            }
            let range = match.range(withName: "identifier")
            guard range.location != NSNotFound else { return nil }
            let word = source.substring(with: range)
            if pythonKeywords.contains(word) {
                expectsName = word == "def" || word == "class"
                return Token(range: range, kind: .literal)
            }
            if declarationName { return Token(range: range, kind: .key) }
            // Attribute names such as obj.format are not Python built-ins.
            if pythonBuiltins.contains(word), range.location == 0 || source.character(at: range.location - 1) != 46 {
                return Token(range: range, kind: .variable)
            }
            return nil
        }
    }
}
