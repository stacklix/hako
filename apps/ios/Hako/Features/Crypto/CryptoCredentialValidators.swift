import Foundation
import CryptoKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private enum CryptoCredentialSignature {
    static func query(_ values: [String: String]) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.~")
        func escape(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: allowed)! }
        return values.keys.sorted().map { escape($0) + "=" + escape(values[$0]!) }.joined(separator: "&")
    }
    static func mac(_ text: String, secret: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: Data(secret.utf8))))
    }
}

struct HTXCredentialValidator: HakoCredentialValidator {
    static let identifier = "crypto.htx"
    static let keys: Set<String> = ["htx.api-key", "htx.secret-key"]
    static func validate(_ credentials: [String: String]) async throws -> HakoCredentialValidationResult {
        try await check(credentials, send: HakoCredentialValidationHTTP.send)
    }
    static func check(_ credentials: [String: String], now: Date = .now,
                      send: HakoCredentialValidationHTTP.Send) async throws -> HakoCredentialValidationResult {
        let host = "api.huobi.pro", path = "/v1/account/accounts"
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        var query = ["AccessKeyId": credentials["htx.api-key"] ?? "", "SignatureMethod": "HmacSHA256",
                     "SignatureVersion": "2", "Timestamp": formatter.string(from: now)]
        query["Signature"] = CryptoCredentialSignature.mac(["GET", host, path, CryptoCredentialSignature.query(query)].joined(separator: "\n"),
            secret: credentials["htx.secret-key"] ?? "").base64EncodedString()
        let request = URLRequest(url: URL(string: "https://" + host + path + "?" + CryptoCredentialSignature.query(query))!, timeoutInterval: 15)
        let response = try await send(request, credentials, .crypto)
        if let code = response.body["err-code"] as? String,
           ["api-signature-not-valid", "api-signature-check-failed", "api-key-not-found", "api-key-not-exist", "api-key-expired"].contains(code) {
            return .init(status: .invalidCredentials, message: "HTX 拒绝了密钥或签名，请检查 Key、Secret、有效期和设备时间。")
        }
        if let failure = HakoCredentialValidationHTTP.failure(response) { return failure }
        guard response.body["status"] as? String == "ok", response.body["data"] is [[String: Any]] else {
            return .init(status: .unavailable, message: "HTX 未返回有效的只读账户响应，请检查读取权限和 IP 白名单。")
        }
        return .init(status: .passed, message: "HTX 只读账户接口已通过签名鉴权；合约等接口仍受各自权限限制。")
    }
}

struct BinanceCredentialValidator: HakoCredentialValidator {
    static let identifier = "crypto.binance"
    static let keys: Set<String> = ["binance.api-key", "binance.secret-key"]
    static func validate(_ credentials: [String: String]) async throws -> HakoCredentialValidationResult {
        try await check(credentials, send: HakoCredentialValidationHTTP.send)
    }
    static func check(_ credentials: [String: String], now: Date = .now,
                      send: HakoCredentialValidationHTTP.Send) async throws -> HakoCredentialValidationResult {
        var query = ["timestamp": String(Int(now.timeIntervalSince1970 * 1000)), "recvWindow": "10000"]
        query["signature"] = CryptoCredentialSignature.mac(CryptoCredentialSignature.query(query), secret: credentials["binance.secret-key"] ?? "")
            .map { String(format: "%02x", $0) }.joined()
        var request = URLRequest(url: URL(string: "https://api.binance.com/sapi/v1/account/apiRestrictions?" + CryptoCredentialSignature.query(query))!, timeoutInterval: 15)
        request.setValue(credentials["binance.api-key"], forHTTPHeaderField: "X-MBX-APIKEY")
        let response = try await send(request, credentials, .crypto)
        switch response.body["code"] as? Int {
        case -2014, -1022: return .init(status: .invalidCredentials, message: "Binance 拒绝了密钥或签名，请核对整组 Key 与 Secret。")
        case -2015: return .init(status: .permissionDenied, message: "Binance 拒绝访问，请检查密钥、IP 白名单和读取权限。")
        case -1021: return .init(status: .unavailable, message: "设备时间超出 Binance 签名窗口，请校准时间后重试。")
        case -1003: return .init(status: .rateLimited, message: "Binance 请求受限，请稍后重试。")
        default: break
        }
        if let failure = HakoCredentialValidationHTTP.failure(response) { return failure }
        guard let reading = response.body["enableReading"] as? Bool else {
            return .init(status: .unavailable, message: "Binance 未返回有效的密钥权限信息。")
        }
        guard reading else { return .init(status: .permissionDenied, message: "密钥鉴权已完成，但尚未开启读取权限。") }
        return .init(status: .passed, message: "Binance 密钥签名和读取权限验证通过。")
    }
}

struct TronscanCredentialValidator: HakoCredentialValidator {
    static let identifier = "crypto.tronscan"
    static let keys: Set<String> = ["tronscan.api-key"]
    static func validate(_ credentials: [String: String]) async throws -> HakoCredentialValidationResult {
        try await check(credentials, send: HakoCredentialValidationHTTP.send)
    }
    static func check(_ credentials: [String: String], send: HakoCredentialValidationHTTP.Send) async throws -> HakoCredentialValidationResult {
        let key = credentials["tronscan.api-key"] ?? ""
        var request = URLRequest(url: URL(string: "https://apilist.tronscanapi.com/api/block?start=0&limit=1")!, timeoutInterval: 15)
        request.setValue(key, forHTTPHeaderField: "TRON-PRO-API-KEY")
        let response = try await send(request, credentials, .crypto)
        if let failure = HakoCredentialValidationHTTP.failure(response) { return failure }
        guard response.body["data"] is [[String: Any]] else {
            return .init(status: .unavailable, message: "TRONSCAN 未返回有效的区块响应。")
        }
        // Some endpoints also serve anonymous/invalid keys at lower limits. A
        // successful public response alone cannot prove that a key was accepted.
        // Change a suffix character rather than prefixes, separators or UUID
        // version bits. Preserve hexadecimal syntax for UUID/hex credentials.
        var characters = Array(key)
        let hexadecimal = key.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789abcdefABCDEF-").contains($0) }
        if let index = characters.indices.reversed().first(where: { characters[$0].isLetter || characters[$0].isNumber }),
           let scalar = characters[index].unicodeScalars.first {
            let value = scalar.value
            if hexadecimal {
                let alphabet = Array(characters[index].isUppercase ? "0123456789ABCDEF" : "0123456789abcdef")
                if let position = alphabet.firstIndex(of: characters[index]) { characters[index] = alphabet[(position + 1) % alphabet.count] }
            } else {
                let changed: UInt32
                switch value {
                case 48...57: changed = 48 + (value - 48 + 1) % 10
                case 65...90: changed = 65 + (value - 65 + 1) % 26
                case 97...122: changed = 97 + (value - 97 + 1) % 26
                default: changed = value
                }
                characters[index] = Character(UnicodeScalar(changed)!)
            }
        }
        let probe = String(characters)
        guard probe != key else { return .init(status: .unavailable, message: "接口可访问，但尚不能确认密钥是否被接受。") }
        try Task.checkCancellation()
        request.setValue(probe, forHTTPHeaderField: "TRON-PRO-API-KEY")
        let control = try await send(request, ["tronscan.api-key": probe], .crypto)
        let controlMessage = ((control.body["message"] as? String) ?? (control.body["error"] as? String) ?? "").lowercased()
        guard control.status == 401 || (control.status == 403 && controlMessage.contains("key")) else {
            return .init(status: .unavailable, message: "区块接口可访问，但未明确区分有效与无效密钥，暂不能确认鉴权成功。")
        }
        return .init(status: .passed, message: "TRONSCAN 区块接口接受了密钥，并拒绝了无效密钥对照请求。")
    }
}

struct MoralisCredentialValidator: HakoCredentialValidator {
    static let identifier = "crypto.moralis"
    static let keys: Set<String> = ["moralis.api-key"]
    static func validate(_ credentials: [String: String]) async throws -> HakoCredentialValidationResult {
        try await check(credentials, send: HakoCredentialValidationHTTP.send)
    }
    static func check(_ credentials: [String: String], send: HakoCredentialValidationHTTP.Send) async throws -> HakoCredentialValidationResult {
        // Public zero address avoids reading any user's wallet or requiring a saved wallet.
        var request = URLRequest(url: URL(string: "https://deep-index.moralis.io/api/v2.2/wallets/0x0000000000000000000000000000000000000000/tokens?chain=eth")!, timeoutInterval: 15)
        request.setValue(credentials["moralis.api-key"], forHTTPHeaderField: "X-API-Key")
        let response = try await send(request, credentials, .crypto)
        if let failure = HakoCredentialValidationHTTP.failure(response) { return failure }
        guard response.body["result"] is [[String: Any]] else {
            return .init(status: .unavailable, message: "Moralis 未返回有效的链上代币查询响应。")
        }
        return .init(status: .passed, message: "Moralis EVM 代币查询接口验证通过；其他链和接口仍受套餐权限限制。")
    }
}
