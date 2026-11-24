import Foundation

struct RandomStringGenerator {
    static let lengthRange = 1...1024
    static let digits = Array("0123456789")
    static let lowercase = Array("abcdefghijklmnopqrstuvwxyz")
    static let uppercase = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    static let punctuation = Array("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")

    var length = 16
    var includesDigits = true
    var includesLowercase = true
    var includesUppercase = true
    var includesPunctuation = false

    private var groups: [[Character]] {
        var groups: [[Character]] = []
        if includesDigits { groups.append(Self.digits) }
        if includesLowercase { groups.append(Self.lowercase) }
        if includesUppercase { groups.append(Self.uppercase) }
        if includesPunctuation { groups.append(Self.punctuation) }
        return groups
    }

    var validationMessage: String? {
        guard Self.lengthRange.contains(length) else { return "长度请输入 1–1024 之间的整数。" }
        guard !groups.isEmpty else { return "请至少选择一种字符类型。" }
        guard length >= groups.count else { return "当前选择了 \(groups.count) 种字符类型，长度至少需要 \(groups.count) 位。" }
        return nil
    }

    enum GenerationError: LocalizedError {
        case invalidOptions(String)

        var errorDescription: String? {
            switch self {
            case .invalidOptions(let message): message
            }
        }
    }

    func generate() throws -> String {
        if let validationMessage { throw GenerationError.invalidOptions(validationMessage) }
        var random = SystemRandomNumberGenerator()
        let selectedGroups = groups
        let characters = selectedGroups.flatMap { $0 }
        // Seed every selected type, fill from the combined pool, then randomize positions.
        var result = selectedGroups.map { $0.randomElement(using: &random)! }
        for _ in result.count..<length {
            result.append(characters.randomElement(using: &random)!)
        }
        result.shuffle(using: &random)
        return String(result)
    }
}
