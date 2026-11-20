import Foundation

@main struct NetworkSSIDCacheTests {
    @MainActor static func main() async {
        var calls = 0
        let cache = NetworkSSIDCache { calls += 1; return "Home" }
        let network = UUID()
        let cellular = await cache.value(usesWiFi: false, generation: network)
        precondition(cellular == nil && calls == 0, "Cellular traffic must not query the Wi-Fi API")
        for _ in 0..<30 {
            let value = await cache.value(usesWiFi: true, generation: network)
            precondition(value == "Home")
        }
        precondition(calls == 1, "Requests on the same network must reuse the cached SSID")
        _ = await cache.value(usesWiFi: true, generation: UUID())
        precondition(calls == 2, "A new network must trigger a fresh lookup")

        var emptyCalls = 0
        let empty = NetworkSSIDCache { emptyCalls += 1; return nil }
        for _ in 0..<10 { _ = await empty.value(usesWiFi: true, generation: network) }
        precondition(emptyCalls == 1, "Unavailable SSIDs must also be cached")

        var concurrentCalls = 0
        var release: CheckedContinuation<String?, Never>?
        let shared = NetworkSSIDCache {
            concurrentCalls += 1
            return await withCheckedContinuation { release = $0 }
        }
        let first = Task { await shared.value(usesWiFi: true, generation: network) }
        let second = Task { await shared.value(usesWiFi: true, generation: network) }
        while release == nil { await Task.yield() }
        for _ in 0..<10 { await Task.yield() }
        precondition(concurrentCalls == 1, "Concurrent requests must share one system lookup")
        release?.resume(returning: "Home")
        let firstValue = await first.value, secondValue = await second.value
        precondition(firstValue == "Home" && secondValue == "Home")

        var staleRelease: CheckedContinuation<String?, Never>?
        var switchedCalls = 0
        let switched = NetworkSSIDCache {
            switchedCalls += 1
            if switchedCalls == 1 { return await withCheckedContinuation { staleRelease = $0 } }
            return "New network"
        }
        let stale = Task { await switched.value(usesWiFi: true, generation: network) }
        while staleRelease == nil { await Task.yield() }
        let offline = await switched.value(usesWiFi: false, generation: UUID())
        precondition(offline == nil && switchedCalls == 1)
        staleRelease?.resume(returning: "Old network")
        let staleValue = await stale.value
        precondition(staleValue == nil, "Old Wi-Fi lookup must not survive a network switch")
        let current = await switched.value(usesWiFi: true, generation: UUID())
        precondition(current == "New network" && switchedCalls == 2)
        print("PASS: Wi-Fi-only lookup, per-network caching, nil caching, concurrent coalescing and stale-result rejection")
    }
}
