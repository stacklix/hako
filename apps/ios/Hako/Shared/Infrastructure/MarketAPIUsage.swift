import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum MarketAPIProvider: String, Codable, CaseIterable, Sendable {
    case tushare, twelveData

    static func matching(_ host: String?) -> Self? {
        switch host?.lowercased() {
        case "api.tushare.pro": .tushare
        case "api.twelvedata.com": .twelveData
        default: nil
        }
    }
}

struct MarketAPIHourUsage: Identifiable, Equatable, Sendable {
    let hour: Date
    let succeeded: Int
    let failed: Int
    var count: Int { succeeded + failed }
    var id: Date { hour }
}

struct MarketAPIUsageSnapshot: Sendable {
    let hours: [MarketAPIHourUsage]
    let failures: [MarketAPIFailure]
    let persistenceFailed: Bool
    var total: Int { hours.reduce(0) { $0 + $1.count } }
    var succeeded: Int { hours.reduce(0) { $0 + $1.succeeded } }
    var failed: Int { hours.reduce(0) { $0 + $1.failed } }
}

struct MarketAPIFailure: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let provider: MarketAPIProvider
    let time: Date
    let endpoint: String
    let httpStatus: Int?
    let code: String?
    let message: String

    var title: String {
        if httpStatus == 429 || code == "429" { return "请求频率超限" }
        if httpStatus == 401 || httpStatus == 403 { return "接口访问被拒绝" }
        if code == "NSURLErrorDomain -1001" { return "网络连接超时" }
        if httpStatus == nil { return "网络请求失败" }
        return String(message.split(whereSeparator: \.isNewline).first.map(String.init)?.prefix(80) ?? "接口请求失败")
    }

    var diagnosticText: String {
        let providerName = provider == .tushare ? "Tushare Pro" : "Twelve Data"
        return "\(providerName)\n请求时间：\(time.formatted(.iso8601))\n接口：\(endpoint)\nHTTP 状态："
            + (httpStatus.map(String.init) ?? "未收到响应")
            + (code.map { "\n错误码：" + $0 } ?? "") + "\n错误信息：\n" + message
    }
}

struct MarketAPIFailureDetail: Sendable {
    let httpStatus: Int?
    let code: String?
    let message: String
}

// Device-wide request attempts, not vendor billing credits. Never store request URLs or keys.
actor MarketAPIUsage {
    enum Outcome: String, Codable, Sendable { case succeeded, failed }
    static let shared = MarketAPIUsage()
    private struct Record: Codable {
        let provider: MarketAPIProvider
        let hour: Date
        var succeeded: Int
        var failed: Int
        var count: Int { succeeded + failed }
    }
    private let file: URL
    private var failureFile: URL { file.deletingPathExtension().appendingPathExtension("failures.json") }
    private var records: [Record]?
    private var failures: [MarketAPIFailure]?
    private var persistenceFailed = false
    private var failuresPersistenceFailed = false
    static let failureLimit = 200

    init(file: URL? = nil) {
        self.file = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hako/MarketAPIUsageResults.json")
    }

    static func hour(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 3600) * 3600)
    }

    private func load() throws {
        guard records == nil else { return }
        records = FileManager.default.fileExists(atPath: file.path)
            ? try JSONDecoder().decode([Record].self, from: Data(contentsOf: file)) : []
    }

    private func loadFailures() throws {
        guard failures == nil else { return }
        failures = FileManager.default.fileExists(atPath: failureFile.path)
            ? try JSONDecoder().decode([MarketAPIFailure].self, from: Data(contentsOf: failureFile)) : []
    }

    private func persistFailures(at date: Date) throws {
        let start = Self.hour(date).addingTimeInterval(-23 * 3600)
        let end = Self.hour(date).addingTimeInterval(3600)
        let recent = (failures ?? []).filter { $0.time >= start && $0.time < end }.sorted { $0.time > $1.time }
        var counts: [MarketAPIProvider: Int] = [:]
        failures = recent.filter { failure in
            counts[failure.provider, default: 0] += 1
            return counts[failure.provider, default: 0] <= Self.failureLimit
        }
        try FileManager.default.createDirectory(at: failureFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(failures ?? []).write(to: failureFile, options: .atomic)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var target = failureFile; try target.setResourceValues(values)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: failureFile.path)
        #endif
        failuresPersistenceFailed = false
    }

    nonisolated static func failureDetail(for request: URLRequest, response: URLResponse? = nil,
                                         data: Data? = nil, error: Error? = nil, secrets: [String] = []) -> MarketAPIFailureDetail {
        let http = response as? HTTPURLResponse
        let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let redactor = HTTPLogRedactor(request: request, secrets: secrets)
        var code: String?
        if let number = object?["code"] as? NSNumber { code = number.stringValue }
        let message: String
        if let error {
            let cause = error as NSError
            code = "\(cause.domain) \(cause.code)"
            message = cause.localizedDescription
        } else if let reason = (object?["message"] as? String) ?? (object?["msg"] as? String), !reason.isEmpty {
            message = reason
        } else if object == nil, let data, data.count <= HTTPLogRedactor.bodyLimit,
                  let body = String(data: data, encoding: .utf8), !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            message = "响应正文：\n" + body
        } else if let http, !(200..<300).contains(http.statusCode) {
            message = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
        } else if object == nil {
            message = "响应不是有效的 JSON 数据。"
        } else if request.url?.path == "/quote" {
            message = "报价无效：缺少有效价格，或返回的标的、币种与请求不符。"
        } else {
            message = "接口返回的数据不完整或格式不符合要求。"
        }
        return MarketAPIFailureDetail(httpStatus: http?.statusCode,
            code: code.map { redactor.diagnosticText($0, limit: 128) },
            message: redactor.diagnosticText(message))
    }

    private static func endpoint(for request: URLRequest) -> String {
        if MarketAPIProvider.matching(request.url?.host) == .tushare,
           let data = request.httpBody,
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let api = object["api_name"] as? String,
           api.range(of: #"^[a-zA-Z0-9_]{1,64}$"#, options: .regularExpression) != nil { return api }
        let path = request.url?.path ?? ""
        return ["/quote", "/time_series", "/symbol_search", "/api_usage"].contains(path) ? path : "行情接口"
    }

    @discardableResult private func prune(at date: Date) -> Bool {
        let end = Self.hour(date), start = end.addingTimeInterval(-23 * 3600)
        let count = records?.count
        records?.removeAll { $0.hour < start || $0.hour > end || $0.count <= 0 }
        return records?.count != count
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(records ?? []).write(to: file, options: .atomic)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var target = file; try target.setResourceValues(values)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
        #endif
        persistenceFailed = false
    }

    // Count completed attempts in their start hour, including provider errors sent as HTTP 200.
    nonisolated static func outcome(for request: URLRequest, response: URLResponse, data: Data) -> Outcome {
        guard let provider = MarketAPIProvider.matching(request.url?.host),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .failed }
        switch provider {
        case .tushare:
            return (object["code"] as? NSNumber)?.intValue == 0 && object["data"] is [String: Any] ? .succeeded : .failed
        case .twelveData:
            if (object["status"] as? String)?.lowercased() == "error" { return .failed }
            if let code = object["code"] as? NSNumber, code.intValue != 200 { return .failed }
            if request.url?.path == "/quote" {
                let close = (object["close"] as? String).flatMap(Double.init) ?? (object["close"] as? NSNumber)?.doubleValue
                let symbol = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "symbol" }?.value
                guard let close, close.isFinite, close > 0,
                      let symbol, (object["symbol"] as? String)?.uppercased() == symbol.uppercased(),
                      (object["currency"] as? String)?.uppercased() == "USD" else { return .failed }
            }
            switch request.url?.path {
            case "/time_series": guard object["values"] is [[String: Any]] else { return .failed }
            case "/symbol_search": guard object["data"] is [[String: Any]] else { return .failed }
            case "/api_usage":
                guard object["current_usage"] is NSNumber, object["plan_limit"] is NSNumber else { return .failed }
            default: break
            }
            return .succeeded
        }
    }

    func record(_ request: URLRequest, outcome: Outcome, failure: MarketAPIFailureDetail? = nil, at date: Date = .now) {
        guard let provider = MarketAPIProvider.matching(request.url?.host) else { return }
        if outcome == .failed {
            do {
                try loadFailures()
                let detail = failure ?? Self.failureDetail(for: request)
                let redactor = HTTPLogRedactor(request: request, secrets: [])
                failures?.append(.init(id: UUID(), provider: provider, time: date,
                    endpoint: redactor.diagnosticText(Self.endpoint(for: request), limit: 128),
                    httpStatus: detail.httpStatus, code: detail.code.map { redactor.diagnosticText($0, limit: 128) },
                    message: redactor.diagnosticText(detail.message)))
                try persistFailures(at: max(date, failures?.map(\.time).max() ?? date))
            } catch { failuresPersistenceFailed = true }
        }
        do {
            try load()
            let hour = Self.hour(date)
            // Older requests can finish after a newer hour has already been recorded.
            let latest = max(hour, records?.map(\.hour).max() ?? hour)
            prune(at: latest)
            guard hour >= latest.addingTimeInterval(-23 * 3600) else { try persist(); return }
            if let index = records?.firstIndex(where: { $0.provider == provider && $0.hour == hour }) {
                if outcome == .succeeded { records![index].succeeded += 1 }
                else { records![index].failed += 1 }
            } else {
                records?.append(Record(provider: provider, hour: hour,
                                       succeeded: outcome == .succeeded ? 1 : 0, failed: outcome == .failed ? 1 : 0))
            }
            try persist()
        } catch { persistenceFailed = true } // Statistics must never block the market request.
    }

    func snapshot(for provider: MarketAPIProvider, at date: Date = .now) throws -> MarketAPIUsageSnapshot {
        try load()
        if prune(at: date) || persistenceFailed {
            do { try persist() } catch { persistenceFailed = true }
        }
        let start = Self.hour(date).addingTimeInterval(-23 * 3600)
        let hours = (0..<24).map { index in
            let hour = start.addingTimeInterval(Double(index) * 3600)
            let matching = records?.filter { $0.provider == provider && $0.hour == hour } ?? []
            return MarketAPIHourUsage(hour: hour,
                succeeded: matching.reduce(0) { $0 + $1.succeeded }, failed: matching.reduce(0) { $0 + $1.failed })
        }
        do {
            try loadFailures()
            if failuresPersistenceFailed || failures?.contains(where: { $0.time < start || $0.time >= Self.hour(date).addingTimeInterval(3600) }) == true {
                try persistFailures(at: date)
            }
        } catch { failuresPersistenceFailed = true }
        return MarketAPIUsageSnapshot(hours: hours,
            failures: (failures ?? []).filter { $0.provider == provider && $0.time >= start && $0.time < Self.hour(date).addingTimeInterval(3600) },
            persistenceFailed: persistenceFailed || failuresPersistenceFailed)
    }
}
