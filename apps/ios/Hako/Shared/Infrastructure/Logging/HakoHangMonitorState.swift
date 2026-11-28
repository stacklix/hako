import Foundation

/// Driven only by a background queue. A single outstanding main-queue probe avoids
/// piling up callbacks while the UI is blocked. Uptime excludes wall-clock changes.
struct HakoHangMonitorState {
    struct Event: Sendable {
        enum Phase: String, Sendable { case blocked, recovered, inactive }
        let id: UUID
        let phase: Phase
        let began: TimeInterval
        let duration: TimeInterval
    }
    private struct Probe {
        let token: UInt64
        let began: TimeInterval
        let id = UUID()
        var lastReport: TimeInterval?
    }
    static let threshold: TimeInterval = 2
    private(set) var active = false
    private var sequence: UInt64 = 0
    private var probe: Probe?

    mutating func setActive(_ value: Bool, now: TimeInterval) -> Event? {
        guard active != value else { return nil }
        active = value
        guard !value else { return nil }
        defer { probe = nil }
        guard let probe, probe.lastReport != nil else { return nil }
        return event(probe, phase: .inactive, now: now)
    }

    mutating func tick(now: TimeInterval) -> (ping: UInt64?, event: Event?) {
        guard active else { return (nil, nil) }
        guard var current = probe else {
            sequence &+= 1
            probe = Probe(token: sequence, began: now)
            return (sequence, nil)
        }
        guard now - current.began >= Self.threshold,
              current.lastReport.map({ now - $0 >= 10 }) ?? true else { return (nil, nil) }
        current.lastReport = now; probe = current
        return (nil, event(current, phase: .blocked, now: now))
    }

    mutating func acknowledge(_ token: UInt64, now: TimeInterval) -> Event? {
        guard active, let current = probe, current.token == token else { return nil }
        probe = nil
        guard now - current.began >= Self.threshold else { return nil }
        return event(current, phase: .recovered, now: now)
    }

    private func event(_ probe: Probe, phase: Event.Phase, now: TimeInterval) -> Event {
        Event(id: probe.id, phase: phase, began: probe.began, duration: max(0, now - probe.began))
    }
}
