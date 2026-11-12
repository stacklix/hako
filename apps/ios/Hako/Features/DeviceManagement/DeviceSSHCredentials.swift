import Foundation

struct DeviceSSHCredentials: Codable {
    var username = ""
    var password = ""
    var fingerprint = ""

    var isValid: Bool {
        (1...256).contains(username.utf8.count) &&
        !username.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) &&
        (1...4096).contains(password.utf8.count) &&
        (fingerprint.isEmpty || Self.validFingerprint(fingerprint))
    }

    static func validFingerprint(_ value: String) -> Bool {
        guard value.hasPrefix("SHA256:"),
              let hash = Data(base64Encoded: String(value.dropFirst(7)) + "="), hash.count == 32 else { return false }
        return value == "SHA256:" + hash.base64EncodedString().dropLast()
    }

    static func offeredFingerprint(_ message: String) -> String? {
        struct HostKey: Decodable { let type: String; let fingerprint: String }
        guard let offer = try? JSONDecoder().decode(HostKey.self, from: Data(message.utf8)),
              offer.type == "ssh_host_key", validFingerprint(offer.fingerprint) else { return nil }
        return offer.fingerprint
    }
}
