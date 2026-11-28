import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct TushareCredentialValidator: HakoCredentialValidator {
    static let identifier = "investment.tushare"
    static let keys: Set<String> = ["tushare.token"]
    static func validate(_ credentials: [String: String]) async throws -> HakoCredentialValidationResult {
        try await check(credentials, send: HakoCredentialValidationHTTP.send)
    }
    static func check(_ credentials: [String: String], now: Date = .now,
                      send: HakoCredentialValidationHTTP.Send) async throws -> HakoCredentialValidationResult {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyyMMdd"
        let day = formatter.string(from: calendar.date(byAdding: .day, value: -1, to: now)!)
        var request = URLRequest(url: URL(string: "https://api.tushare.pro/")!, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["api_name": "trade_cal",
            "token": credentials["tushare.token"] ?? "", "params": ["exchange": "SSE", "start_date": day, "end_date": day], "fields": "cal_date"])
        let response = try await send(request, credentials, .investment)
        if let failure = HakoCredentialValidationHTTP.failure(response) { return failure }
        let code = response.body["code"] as? Int
        if code == 2002 { return .init(status: .permissionDenied, message: "Tushare 交易日历接口拒绝访问，请检查 Token 和该接口权限。") }
        guard code == 0, let data = response.body["data"] as? [String: Any],
              let fields = data["fields"] as? [String], let index = fields.firstIndex(of: "cal_date"),
              let rows = data["items"] as? [[Any]], rows.contains(where: { $0.count > index && $0[index] as? String == day }) else {
            return .init(status: .unavailable, message: "Tushare 未返回有效的交易日历，暂不能确认凭据可用。")
        }
        return .init(status: .passed, message: "交易日历接口验证通过；其他行情接口仍受各自权限和配额限制。")
    }
}

struct TwelveDataCredentialValidator: HakoCredentialValidator {
    static let identifier = "investment.twelve-data"
    static let keys: Set<String> = ["twelve-data.api-key"]
    static func validate(_ credentials: [String: String]) async throws -> HakoCredentialValidationResult {
        try await check(credentials, send: HakoCredentialValidationHTTP.send)
    }
    static func check(_ credentials: [String: String], send: HakoCredentialValidationHTTP.Send) async throws -> HakoCredentialValidationResult {
        var url = URLComponents(string: "https://api.twelvedata.com/api_usage")!
        url.queryItems = [.init(name: "apikey", value: credentials["twelve-data.api-key"] ?? "")]
        url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        let response = try await send(URLRequest(url: url.url!, timeoutInterval: 15), credentials, .investment)
        if let code = response.body["code"] as? Int,
           let failure = HakoCredentialValidationHTTP.failure(.init(status: code, body: [:])) { return failure }
        if let failure = HakoCredentialValidationHTTP.failure(response) { return failure }
        guard response.body["code"] == nil, response.body["current_usage"] is NSNumber, response.body["plan_limit"] is NSNumber else {
            return .init(status: .unavailable, message: "Twelve Data 未返回有效的密钥用量信息。")
        }
        return .init(status: .passed, message: "密钥用量接口验证通过；投资记账与加密资产共用此凭据。")
    }
}
