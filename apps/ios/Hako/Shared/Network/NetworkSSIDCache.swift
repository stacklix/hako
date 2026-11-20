import Foundation

// A network generation owns one lookup, including an unavailable/nil result.
// Concurrent callers await the same lookup; stale completions cannot repopulate
// the cache after the phone changes networks.
@MainActor final class NetworkSSIDCache {
    private let fetch: () async -> String?
    private var generation: UUID?
    private var cached = false
    private var ssid: String?
    private var pending: (id: UUID, task: Task<String?, Never>)?

    init(fetch: @escaping () async -> String?) { self.fetch = fetch }

    func invalidate() {
        pending?.task.cancel(); pending = nil
        generation = nil; cached = false; ssid = nil
    }

    func value(usesWiFi: Bool, generation: UUID) async -> String? {
        guard usesWiFi else { invalidate(); return nil }
        if self.generation != generation {
            invalidate(); self.generation = generation
        }
        if cached { return ssid }
        let lookup: (id: UUID, task: Task<String?, Never>)
        if let pending { lookup = pending }
        else {
            let fetch = self.fetch
            lookup = (UUID(), Task { await fetch() })
            pending = lookup
        }
        let result = await lookup.task.value
        guard self.generation == generation, !lookup.task.isCancelled else { return nil }
        if pending?.id == lookup.id {
            ssid = result; cached = true; pending = nil
        }
        return Task.isCancelled ? nil : result
    }
}
