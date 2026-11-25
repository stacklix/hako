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
        precondition(HakoCodeSyntax.language(filename: "hako/hako_market_sync.py") == .python)
        precondition(HakoCodeSyntax.language(filename: "SCRIPT.PYW") == .python)
        precondition(HakoCodeSyntax.language(filename: "typing.pyi") == .python)
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
        let python = #"""
        # 行情😀
        from decimal import Decimal
        @staticmethod
        def number(value):
            try:
                result = Decimal(str(value))
                if not result.is_finite() or result <= 0:
                    raise ValueError("行情源返回无效或非正数价格") from None
                return result
            except (ValueError, TypeError):
                return False
        class Price:
            precision = 50
        """#
        expect(python, .python, [("# 行情😀", .comment), ("from", .literal), ("import", .literal),
               ("@staticmethod", .variable), ("def", .literal), ("number", .key), ("str", .variable),
               ("try", .literal), ("if", .literal), ("not", .literal), ("or", .literal),
               ("raise", .literal), ("ValueError", .variable), ("\"行情源返回无效或非正数价格\"", .string),
               ("None", .literal), ("return", .literal), ("except", .literal), ("False", .literal),
               ("class", .literal), ("Price", .key), ("50", .number)])
        expect("value=1#inline😀\ntext=\"# not a comment\"\n", .python,
               [("1", .number), ("#inline😀", .comment), ("\"# not a comment\"", .string)])
        expect(#"raw = r"C:\temp\data"; data = b'bytes'; label = f"价格: {value}"; text = 'it\'s ok'"#, .python,
               [(#"r"C:\temp\data""#, .string), ("b'bytes'", .string), (#"f"价格: {value}""#, .string), (#"'it\'s ok'"#, .string)])
        expect("x=0xFF_FF; y=0b1010; z=0o755; price=.25; a=1.; b=1_000.5e-2; c=2j", .python,
               [("0xFF_FF", .number), ("0b1010", .number), ("0o755", .number), (".25", .number),
                ("1.", .number), ("1_000.5e-2", .number), ("2j", .number)])
        expect("def\tformat(value):\n    return value.format()\n", .python, [("format", .key), ("return", .literal)])
        expect("    @cache.memoize\n    def value():\n        return\"ok\"\n", .python,
               [("@cache.memoize", .variable), ("value", .key), ("return", .literal), ("\"ok\"", .string)])
        precondition(HakoCodeSyntax.tokens("left @ right", language: .python).isEmpty, "Matrix multiplication is not a decorator")
        let protected: [String] = [
            "\"key\":", "\"def return # inside\"", "'''\nfrom False # 文档😀\n'''",
            "\"\"\"多行\ndef ignored():\n# inside\n\"\"\"", "r'''\n路径\\data\n'''",
            "\"\"\"未完成😀\ndef ignored():", "\"未完成 # return😀"
        ]
        for source in protected {
            let tokens = HakoCodeSyntax.tokens(source, language: .python)
            precondition(tokens.count == 1 && tokens[0].kind == .string, "Strings must shield their contents: \(source)")
            precondition(tokens[0].range.location == 0 && NSMaxRange(tokens[0].range) <= (source as NSString).length)
        }
        precondition(HakoCodeSyntax.tokens("return_value = obj.format; true_value = 'x'", language: .python)
            .allSatisfy { $0.kind == .string }, "Identifier substrings and member names must not become keywords/built-ins")
        precondition(HakoCodeSyntax.tokens("# def return True 123", language: .python).count == 1)
        expect("'unfinished\nreturn True\n", .python, [("'unfinished", .string), ("return", .literal), ("True", .literal)])
        expect("", .python, [])
        let largePython = String(repeating: "# 😀\ndef value(x):\n    return x + 1\n", count: 1000)
        expect(largePython, .python, [("value", .key), ("return", .literal), ("1", .number)])
        print("PASS: configuration and Python detection, UTF-16 ranges, keywords, declarations, decorators, built-ins, strings, comments, numeric forms and unfinished input")
    }
}
