import Foundation

struct ECSAccessBinding: Codable, Equatable {
    var origin: String
    var account: String
    var domains: [String]

    static func key(_ connection: ECSConnection) -> String {
        "ecs.access.binding.\(connection.region).\(connection.instanceID)"
    }
    static func load(_ connection: ECSConnection) -> Self? {
        guard let data = UserDefaults.standard.data(forKey: key(connection)) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
    func save(_ connection: ECSConnection) throws {
        let value = Self(origin: origin, account: account, domains: Array(Set(domains)).sorted())
        UserDefaults.standard.set(try JSONEncoder().encode(value), forKey: Self.key(connection))
        UserDefaults.standard.set(UUID().uuidString, forKey: "ecs.access.revision")
    }
    func matches(origin: String, account: String) -> Bool { self.origin == origin && self.account == account }
}

enum ECSAccessRange: Int, CaseIterable, Identifiable {
    case hour = 1, threeHours = 3, twelveHours = 12, day = 24, threeDays = 72, week = 168
    var id: Int { rawValue }
    var label: String { rawValue < 24 ? "近 \(rawValue) 小时" : "近 \(rawValue / 24) 天" }
}

enum ECSAccessDate {
    static func parse(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        if let value = formatter.date(from: text) { return value }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: text)
    }
}

enum ECSAccessQuery {
    static func path(rankings: Bool, range: ECSAccessRange, domain: String,
                     from: String?, to: String?, hour: String?) -> String {
        var query = URLComponents()
        query.queryItems = [URLQueryItem(name: "rangeHours", value: String(range.rawValue))]
        for (name, value) in [("domain", domain.isEmpty ? nil : domain), ("from", from), ("to", to), ("hour", hour)] {
            if let value { query.queryItems?.append(URLQueryItem(name: name, value: value)) }
        }
        // Go's URL.Query uses form decoding: literal + must survive as %2B,
        // especially the timezone offsets in fixed-window requests.
        let encoded = (query.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        return "/api/v1/access-logs" + (rankings ? "/rankings" : "") + "?" + encoded
    }
}

enum ECSAccessHealth: Equatable { case disabled, waiting, scanning, healthy, delayed, failed }

struct ECSAccessStatus: Decodable {
    let enabled: Bool
    let timezone: String
    let scanIntervalSeconds: Int
    let retentionDays: Int
    let scanning: Bool
    let lastScan: String?
    let error: String?

    var scanDate: Date? { ECSAccessDate.parse(lastScan) }
    var scanError: String? {
        let value = (error ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
    func health(at now: Date = .now) -> ECSAccessHealth {
        guard enabled else { return .disabled }
        // lastScan is the end of an attempt, including failed attempts.
        // A current timestamp never rules out unreadable or invalid log files.
        if scanError != nil { return .failed }
        guard let scanDate else { return scanning ? .scanning : .waiting }
        if now.timeIntervalSince(scanDate) > Double(max(180, scanIntervalSeconds * 3)) { return .delayed }
        return .healthy
    }
    func delayed(at now: Date = .now) -> Bool { health(at: now) == .delayed }
}

struct ECSAccessCount: Decodable, Identifiable {
    let domain: String
    let hour: String?
    let visits: Int64
    let notFound: Int64
    var id: String { domain + (hour ?? "") }
    var missingRate: Double { visits > 0 ? Double(notFound) / Double(visits) * 100 : 0 }
}

struct ECSAccessBucket: Identifiable {
    let time: Date
    var visits: Int64 = 0
    var notFound: Int64 = 0
    // Hourly points can be drilled into with the server's original timezone.
    var hour: String?
    var id: Date { time }
}

struct ECSAccessSummary: Decodable {
    let status: ECSAccessStatus
    let rangeHours: Int?
    let from: String?
    let to: String?
    let domains: [String]
    let hours: [ECSAccessCount]
    let totals: [ECSAccessCount]
    let truncated: Bool?

    func counts(domains selected: [String]) -> [ECSAccessCount] {
        let allowed = Set(selected)
        return totals.filter { allowed.contains($0.domain) }.sorted {
            $0.visits == $1.visits ? $0.domain < $1.domain : $0.visits > $1.visits
        }
    }
    func buckets(domains selected: [String], daily: Bool) -> [ECSAccessBucket] {
        guard let start = ECSAccessDate.parse(from), let end = ECSAccessDate.parse(to), start <= end else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: status.timezone) ?? TimeZone(secondsFromGMT: 0)!
        let component: Calendar.Component = daily ? .day : .hour
        func floor(_ time: Date) -> Date { calendar.dateInterval(of: component, for: time)!.start }
        let allowed = Set(selected)
        var values: [Date: ECSAccessBucket] = [:]
        var cursor = floor(start)
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = calendar.timeZone
        while cursor <= end && values.count < 200 {
            values[cursor] = ECSAccessBucket(time: cursor, hour: daily ? nil : formatter.string(from: cursor))
            guard let next = calendar.date(byAdding: component, value: 1, to: cursor), next > cursor else { break }
            cursor = next
        }
        for row in hours where allowed.contains(row.domain) {
            guard let hour = row.hour, let time = formatter.date(from: hour), values[floor(time)] != nil else { continue }
            let key = floor(time)
            values[key]!.visits += row.visits
            values[key]!.notFound += row.notFound
            if !daily { values[key]!.hour = row.hour }
        }
        return values.values.sorted { $0.time < $1.time }
    }
}

struct ECSAccessRank: Decodable, Identifiable {
    let value: String
    let count: Int64
    var id: String { value }
}
struct ECSAccessClient: Decodable, Identifiable {
    let value: String
    let count: Int64
    let userAgents: [ECSAccessRank]
    let urls: [ECSAccessRank]
    var id: String { value }
}
struct ECSAccessMissingPage: Decodable, Identifiable {
    let value: String
    let count: Int64
    let ips: [ECSAccessRank]
    let userAgents: [ECSAccessRank]
    var id: String { value }
}
struct ECSAccessRankings: Decodable {
    let domain: String
    let hour: String
    let from: String
    let to: String
    let visits: Int64
    let notFound: Int64
    let topClients: [ECSAccessClient]
    let topURLs: [ECSAccessRank]
    let notFoundPages: [ECSAccessMissingPage]
    let notFoundIPs: [ECSAccessRank]
    let notFoundUserAgents: [ECSAccessRank]
}
