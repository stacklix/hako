import Foundation

struct ConsoleAgentRegistration {
    let id: String
    let name: String
    let publicKeyPEM: String

    var body: [String: Any] { ["id": id, "name": name, "publicKeyPem": publicKeyPEM] }

    init(id: String, name: String, publicKeyPEM: String) throws {
        self.id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.publicKeyPEM = try Self.validatePublicKey(publicKeyPEM)
        guard !self.id.isEmpty, self.id.utf8.count <= 80,
              self.id.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45 }) else {
            throw ConsoleAgentRegistrationError.invalidID
        }
        guard !self.name.isEmpty, self.name.utf8.count <= 100 else { throw ConsoleAgentRegistrationError.invalidName }
        guard try JSONSerialization.data(withJSONObject: body).count <= 16 * 1024 else { throw ConsoleAgentRegistrationError.tooLarge }
    }

    // Reject private keys locally, before a request or file import can transmit them.
    // The server checks the RSA algorithm and key size and normalizes the public key.
    static func validatePublicKey(_ value: String) throws -> String {
        guard !value.uppercased().contains("PRIVATE KEY") else { throw ConsoleAgentRegistrationError.privateKey }
        guard value.utf8.count <= 16 * 1024 else { throw ConsoleAgentRegistrationError.tooLarge }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = text.split(whereSeparator: { $0.isNewline })
        let type = lines.first == "-----BEGIN RSA PUBLIC KEY-----" ? "RSA PUBLIC KEY" : "PUBLIC KEY"
        guard lines.count >= 3, lines.first == Substring("-----BEGIN \(type)-----"),
              lines.last == Substring("-----END \(type)-----"),
              let decoded = Data(base64Encoded: lines.dropFirst().dropLast().joined()), !decoded.isEmpty else {
            throw ConsoleAgentRegistrationError.invalidPublicKey
        }
        return text
    }
}

enum ConsoleAgentRegistrationError: LocalizedError {
    case invalidID, invalidName, privateKey, invalidPublicKey, tooLarge

    var errorDescription: String? {
        switch self {
        case .invalidID: return "设备 ID 应为 1–80 位英文字母、数字、下划线或连字符。"
        case .invalidName: return "设备名称不能为空或过长，请缩短后重试。"
        case .privateKey: return "请使用 Windows 导出的公钥，不要粘贴或导入私钥。"
        case .invalidPublicKey: return "请提供完整的 PEM 公钥，包含 BEGIN 和 END PUBLIC KEY 标记。"
        case .tooLarge: return "公钥或登记内容过大，请检查是否只包含一个 PEM 公钥。"
        }
    }
}
