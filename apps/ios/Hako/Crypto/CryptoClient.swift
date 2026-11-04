import Foundation
import CryptoKit

// Only read endpoints; signed requests use the host's no-redirect transport.
struct CryptoClient {
    let session: URLSession
    init(session: URLSession = HTTPTransport.shared) { self.session=session }
    static func number(_ value: Any?) throws -> Double {
        let n: Double?
        if let s = value as? String { n = Double(s) } else { n = (value as? NSNumber)?.doubleValue }
        guard let n, n.isFinite else { throw HakoError(message: "资产接口返回了无效数值。") }
        return n
    }
    func json(_ request: URLRequest) async throws -> Any {
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw HakoError(message: "资产接口请求失败，请检查权限、网络及设备时间。") }
            let value = try JSONSerialization.jsonObject(with: data)
            if let o = value as? [String: Any], o["status"] as? String == "error" { throw HakoError(message: "HTX 接口拒绝请求，请检查只读 API 配置及权限。") }
            return value
        } catch is CancellationError { throw CancellationError() }
        catch { throw HakoError(message: "资产接口请求失败，请检查配置、网络及设备时间。") }
    }
    static func escape(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.~"))! }
    static func query(_ values: [String: String]) -> String { values.keys.sorted().map { escape($0) + "=" + escape(values[$0]!) }.joined(separator: "&") }
    static func mac(_ data: String, secret: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(data.utf8), using: SymmetricKey(data: Data(secret.utf8))))
    }
    func htx(_ host: String, _ path: String, credential: CryptoCredential? = nil, params: [String: String] = [:], body: [String: Any]? = nil) async throws -> [String: Any] {
        let method = body == nil ? "GET" : "POST"
        var q = params
        if let credential {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            q.merge(["AccessKeyId":credential.key,"SignatureMethod":"HmacSHA256","SignatureVersion":"2","Timestamp":f.string(from: .now)]) { _, new in new }
            q["Signature"] = Self.mac([method,host,path,Self.query(q)].joined(separator: "\n"), secret: credential.secret).base64EncodedString()
        }
        var r = URLRequest(url: URL(string: "https://" + host + path + "?" + Self.query(q))!); r.httpMethod = method
        if let body { r.httpBody = try JSONSerialization.data(withJSONObject: body); r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        guard let object = try await json(r) as? [String: Any] else { throw HakoError(message: "HTX 返回格式无效。") }; return object
    }
    func htxTotal(_ c: CryptoCredential) async throws -> Double {
        let o = try await htx("api.huobi.pro", "/v2/account/valuation", credential: c, params: ["valuationCurrency":"BTC"])
        guard o["success"] as? Bool == true, let d = o["data"] as? [String: Any],
              let updated = d["updated"] as? [String: Any], updated["success"] as? Bool == true,
              let accounts = d["profitAccountBalanceList"] as? [[String: Any]],
              accounts.allSatisfy({ $0["success"] as? Bool == true }) else { throw HakoError(message: "HTX 总资产数据未完整更新。") }
        return try Self.number(d["totalBalance"]) * (try await price("BTC"))
    }
    func binanceTotal(_ c: CryptoCredential) async throws -> Double {
        var q = ["timestamp":String(Int(Date.now.timeIntervalSince1970*1000)),"recvWindow":"10000","quoteAsset":"USDT"]
        let signature = Self.mac(Self.query(q), secret:c.secret).map { String(format:"%02x",$0) }.joined()
        q["signature"] = signature
        var r = URLRequest(url: URL(string:"https://api.binance.com/sapi/v1/asset/wallet/balance?" + Self.query(q))!)
        r.setValue(c.key, forHTTPHeaderField:"X-MBX-APIKEY")
        guard let data = try await json(r) as? [[String: Any]] else { throw HakoError(message:"Binance 总资产格式无效。") }
        return try data.reduce(0) { sum, row in sum + (try Self.number(row["balance"])) }
    }
    func price(_ symbol: String) async throws -> Double {
        if symbol == "USDT" { return 1 }
        let o = try await htx("api.huobi.pro", "/market/detail/merged", params:["symbol":symbol.lowercased()+"usdt"])
        guard let tick = o["tick"] as? [String: Any] else { throw HakoError(message:"缺少 \(symbol) 的 USDT 报价。") }
        let price = try Self.number(tick["close"])
        guard price > 0 else { throw HakoError(message:"资产价格无效。") }; return price
    }
}
