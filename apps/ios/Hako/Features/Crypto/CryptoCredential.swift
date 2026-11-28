import Foundation
import CryptoKit

struct CryptoCredential: Codable {
    var key = ""
    var secret = ""
    var configured: Bool { !key.isEmpty && !secret.isEmpty }
    static func twelveDataKey() throws -> String {
        try HakoTokens.read("twelve-data.api-key")
    }
    static func load(_ exchange: String) throws -> Self {
        let values = try HakoTokens.readGroup(containing: exchange + ".api-key")
        let key = values[exchange + ".api-key"] ?? ""
        return Self(key: key, secret: values[exchange + ".secret-key"] ?? key)
    }

}

extension CryptoDay {
    static func hash(_ string: String) -> String { SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined() }
}
