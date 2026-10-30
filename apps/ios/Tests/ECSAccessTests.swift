import Foundation

@main struct ECSAccessTests {
    static func main() throws {
        let data = Data(#"""
        {"status":{"enabled":true,"timezone":"Asia/Shanghai","scanIntervalSeconds":60,"retentionDays":7,"scanning":false,"lastScan":"2026-10-30T10:00:00.123Z"},
         "rangeHours":3,"from":"2026-10-30T16:30:00+08:00","to":"2026-10-30T19:30:00+08:00","domains":["a.test","b.test","foreign.test"],"truncated":false,
         "totals":[{"domain":"a.test","visits":20,"notFound":2},{"domain":"b.test","visits":10,"notFound":1},{"domain":"foreign.test","visits":1000,"notFound":1000}],
         "hours":[{"domain":"a.test","hour":"2026-10-30T16:00:00+08:00","visits":5,"notFound":1},{"domain":"a.test","hour":"2026-10-30T19:00:00+08:00","visits":15,"notFound":1},{"domain":"b.test","hour":"2026-10-30T19:00:00+08:00","visits":10,"notFound":1},{"domain":"foreign.test","hour":"2026-10-30T19:00:00+08:00","visits":1000,"notFound":1000}]}
        """#.utf8)
        let summary = try JSONDecoder().decode(ECSAccessSummary.self, from: data)
        let selected = ["a.test", "b.test", "not-in-window.test"]
        let counts = summary.counts(domains: selected)
        precondition(counts.count == 2 && counts.reduce(0) { $0 + $1.visits } == 30)
        precondition(counts[0].missingRate == 10 && counts[0].hour == nil)
        let points = summary.buckets(domains: selected, daily: false)
        precondition(points.count == 4 && points[1].visits == 0 && points[1].hour != nil)
        precondition(points.reduce(0) { $0 + $1.visits } == 30)
        precondition(points.reduce(0) { $0 + $1.notFound } == 3)
        precondition(summary.buckets(domains: ["a.test"], daily: false).last?.visits == 15)
        let daily = summary.buckets(domains: selected, daily: true)
        precondition(daily.count == 1 && daily[0].visits == 30 && daily[0].hour == nil)
        precondition(daily[0].time == ECSAccessDate.parse("2026-10-30T00:00:00+08:00"))
        precondition(!summary.status.delayed(at: ECSAccessDate.parse("2026-10-30T10:01:00Z")!))
        precondition(summary.status.delayed(at: ECSAccessDate.parse("2026-10-30T10:04:00Z")!))

        let disabled = try JSONDecoder().decode(ECSAccessSummary.self, from: Data(#"{"status":{"enabled":false,"timezone":"","scanIntervalSeconds":0,"retentionDays":7,"scanning":false},"domains":[],"hours":[],"totals":[]}"#.utf8))
        precondition(!disabled.status.enabled && disabled.buckets(domains: [], daily: false).isEmpty)
        precondition(!disabled.status.delayed())

        // A day begins in the source timezone, not in the phone's timezone.
        let offsetData = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "Asia/Shanghai", with: "Asia/Kathmandu")
            .replacingOccurrences(of: "+08:00", with: "+05:45")
        let offset = try JSONDecoder().decode(ECSAccessSummary.self, from: Data(offsetData.utf8))
        precondition(offset.buckets(domains: selected, daily: false).count == 4)
        precondition(offset.buckets(domains: selected, daily: true)[0].time == ECSAccessDate.parse("2026-10-30T00:00:00+05:45"))

        let ranks = try JSONDecoder().decode(ECSAccessRankings.self, from: Data(#"""
        {"domain":"a.test","hour":"","from":"2026-10-30T00:00:00Z","to":"2026-10-30T01:00:00Z","visits":4,"notFound":2,
         "topClients":[{"value":"192.0.2.1","count":4,"userAgents":[{"value":"bot","count":4}],"urls":[{"value":"/","count":4}]}],
         "topURLs":[{"value":"/","count":4}],"notFoundPages":[{"value":"/missing","count":2,"ips":[{"value":"192.0.2.1","count":2}],"userAgents":[{"value":"bot","count":2}]}],"notFoundIPs":[],"notFoundUserAgents":[]}
        """#.utf8))
        precondition(ranks.topClients[0].userAgents[0].value == "bot")
        precondition(ranks.notFoundPages[0].ips[0].count == 2 && ranks.topURLs[0].count == 4)
        let a = ECSConnection(region: "cn-chengdu", instanceID: "i-a")
        let b = ECSConnection(region: "cn-chengdu", instanceID: "i-b")
        precondition(ECSAccessBinding.key(a) != ECSAccessBinding.key(b))
        let binding = ECSAccessBinding(origin: "https://hako.test", account: "owner", domains: selected)
        precondition(binding.matches(origin: "https://hako.test", account: "owner"))
        precondition(!binding.matches(origin: "https://other.test", account: "owner"))
        precondition(!binding.matches(origin: "https://hako.test", account: "other"))
        let query = ECSAccessQuery.path(rankings: true, range: .day, domain: "a.test&domain=foreign.test",
            from: "2026-10-30T00:00:00+08:00", to: "2026-10-31T00:00:00+08:00", hour: nil)
        precondition(!query.contains("+"))
        let items = URLComponents(string: query)!.queryItems!
        precondition(items.filter { $0.name == "domain" }.count == 1)
        precondition(items.first { $0.name == "domain" }!.value == "a.test&domain=foreign.test")
        precondition(items.first { $0.name == "from" }!.value == "2026-10-30T00:00:00+08:00")
        print("ECS access statistics tests passed")
    }
}
