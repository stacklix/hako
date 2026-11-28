import Foundation

@main struct HakoHangMonitorTests {
    static func main() {
        var state = HakoHangMonitorState()
        precondition(state.tick(now: 0).ping == nil)
        precondition(state.setActive(true, now: 0) == nil)
        let ping = state.tick(now: 1).ping!
        precondition(state.tick(now: 2.9).event == nil)
        let blocked = state.tick(now: 3).event!
        precondition(blocked.phase == .blocked && blocked.duration == 2)
        // One outstanding callback; long stalls update one durable report at most every 10 seconds.
        for second in 4...12 { let tick = state.tick(now: Double(second)); precondition(tick.ping == nil && tick.event == nil) }
        let prolonged = state.tick(now: 13).event!
        precondition(prolonged.id == blocked.id && prolonged.duration == 12)
        let recovered = state.acknowledge(ping, now: 14)!
        precondition(recovered.id == blocked.id && recovered.phase == .recovered && recovered.duration == 13)
        precondition(state.acknowledge(ping, now: 15) == nil)

        let second = state.tick(now: 15).ping!
        precondition(state.acknowledge(second, now: 15.1) == nil)
        // Delayed timer delivery still captures a stall when the main queue returns.
        let delayed = state.tick(now: 16).ping!
        let delayedRecovery = state.acknowledge(delayed, now: 20)!
        precondition(delayedRecovery.phase == .recovered && delayedRecovery.duration == 4)

        let beforeBackground = state.tick(now: 21).ping!
        precondition(state.setActive(false, now: 21.5) == nil)
        precondition(state.tick(now: 200).event == nil)
        _ = state.setActive(true, now: 200)
        let afterBackground = state.tick(now: 201).ping!
        precondition(beforeBackground != afterBackground)
        precondition(state.acknowledge(beforeBackground, now: 202) == nil)
        precondition(state.acknowledge(afterBackground, now: 201.1) == nil)

        _ = state.tick(now: 203)
        let activeStall = state.tick(now: 205).event!
        let paused = state.setActive(false, now: 205.5)!
        precondition(paused.id == activeStall.id && paused.phase == .inactive && paused.duration == 2.5)
        precondition(state.tick(now: 50_000).ping == nil)
        print("Hang monitor threshold, bounded probes, recovery, stale callbacks and background exclusion passed")
    }
}
