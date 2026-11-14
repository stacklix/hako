import Foundation

@main struct ArcaneSyntaxTests {
    static func main() {
        precondition(HakoCodeSyntax.language(filename: "config/compose.yml") == .yaml)
        precondition(HakoCodeSyntax.language(filename: ".env") == .env)
        precondition(HakoCodeSyntax.language(filename: ".env.production") == .env)
        precondition(HakoCodeSyntax.language(filename: "project.env") == .env)
        precondition(HakoCodeSyntax.language(filename: "settings.JSON") == .json)
        precondition(HakoCodeSyntax.language(filename: "app.toml") == .toml)
        precondition(HakoCodeSyntax.language(filename: "start.sh") == .shell)
        precondition(HakoCodeSyntax.language(filename: "README.txt") == .plain)

        func expect(_ source: String, _ language: HakoCodeSyntax.Language, _ expected: [(String, HakoCodeSyntax.Kind)]) {
            let tokens = HakoCodeSyntax.tokens(source, language: language)
            let text = source as NSString
            var end = 0
            for token in tokens {
                precondition(token.range.location >= end && token.range.length > 0 && NSMaxRange(token.range) <= text.length,
                             "Highlight ranges must be ordered, disjoint and valid UTF-16 offsets")
                end = NSMaxRange(token.range)
            }
            for (value, kind) in expected {
                precondition(tokens.contains { $0.kind == kind && text.substring(with: $0.range) == value },
                             "Missing \(kind.rawValue) token: \(value)")
            }
        }
        expect("services:\n  web:\n    image: 'nginx:alpine' # 镜像\n    enabled: true\n    replicas: 3\n", .yaml,
               [("services", .key), ("image", .key), ("'nginx:alpine'", .string), ("# 镜像", .comment), ("true", .literal), ("3", .number)])
        expect("# 配置😀\r\nTOKEN=\"abc#123\"\r\nPORT=8080\r\nHOST=${DOMAIN}\r\n", .env,
               [("# 配置😀", .comment), ("TOKEN", .key), ("\"abc#123\"", .string), ("8080", .number), ("${DOMAIN}", .variable)])
        expect(##"{"标题😀": "a\"#b", "enabled": false, "value": -2.5e3, "empty": null}"##, .json,
               [("\"标题😀\"", .key), (##""a\"#b""##, .string), ("false", .literal), ("-2.5e3", .number), ("null", .literal)])
        expect("# comment\nexport NAME='hello'\necho $NAME\n", .shell,
               [("# comment", .comment), ("export", .literal), ("NAME", .key), ("'hello'", .string), ("$NAME", .variable)])
        expect("; comment\nport = 42\n", .toml, [("; comment", .comment), ("port", .key), ("42", .number)])
        expect("url: https://host/path#part\n", .yaml, [("url", .key)])
        precondition(!HakoCodeSyntax.tokens("url: https://host/path#part\n", language: .yaml).contains { $0.kind == .comment })
        precondition(!HakoCodeSyntax.tokens("A=8080abc\n", language: .env).contains { $0.kind == .number })
        precondition(HakoCodeSyntax.tokens("# ordinary text: true", language: .plain).isEmpty)
        precondition(HakoCodeSyntax.tokens("", language: .yaml).isEmpty)
        let incomplete = "key: \"未完成😀\n"
        for token in HakoCodeSyntax.tokens(incomplete, language: .yaml) {
            precondition(NSMaxRange(token.range) <= (incomplete as NSString).length)
        }
        print("PASS: configuration language detection, UTF-16/emoji ranges, quoted keys, escaped strings, comments, numbers, variables and incomplete input")
    }
}
