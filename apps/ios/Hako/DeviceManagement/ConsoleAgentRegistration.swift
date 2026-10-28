import Foundation

struct ConsoleAgentRegistration {
    let name: String
    let publicKeyPEM: String

    var body: [String: Any] { ["name": name, "publicKeyPem": publicKeyPEM] }

    init(name: String, publicKeyPEM: String) throws {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.publicKeyPEM = try Self.validatePublicKey(publicKeyPEM)
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

struct ConsoleAgentRegistrationReply: Decodable {
    let id: String
    let keyId: String
}

enum ConsoleAgentRegistrationError: LocalizedError {
    case invalidName, privateKey, invalidPublicKey, tooLarge

    var errorDescription: String? {
        switch self {
        case .invalidName: return "设备名称不能为空或过长，请缩短后重试。"
        case .privateKey: return "请使用 Agent 导出的公钥，不要粘贴或导入私钥。"
        case .invalidPublicKey: return "请提供完整的 PEM 公钥，包含 BEGIN 和 END PUBLIC KEY 标记。"
        case .tooLarge: return "公钥或登记内容过大，请检查是否只包含一个 PEM 公钥。"
        }
    }
}
