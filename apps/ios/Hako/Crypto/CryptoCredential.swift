import Foundation
import CryptoKit

struct CryptoCredential: Codable {
    var key = ""
    var secret = ""
    var configured: Bool { !key.isEmpty && !secret.isEmpty }
    static func load(_ exchange: String) throws -> Self {
        guard let data = try SecureStorage.namespace("me.stackli.hako.crypto").read(account: exchange) else { return Self() }
        return try JSONDecoder().decode(Self.self, from: data)
    }
    func save(_ exchange: String) throws {
        guard key.isEmpty == secret.isEmpty else { throw HakoError(message: "请同时填写 API Key 与 Secret Key。") }
        try SecureStorage.namespace("me.stackli.hako.crypto").save(JSONEncoder().encode(self), account: exchange, accessibility: .afterFirstUnlock)
    }
}

extension CryptoDay {
    static func hash(_ string: String) -> String { SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined() }
}
