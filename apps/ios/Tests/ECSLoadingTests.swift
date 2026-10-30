import Foundation

private actor ECSMockReader: ECSReading {
    private(set) var calls: [String] = []
    private(set) var cancelled: [String] = []
    private(set) var maximumActive = 0
    private var active = 0
    private var holdOnce: Set<String>
    private let delay: Bool

    init(holdOnce: Set<String> = [], delay: Bool = false) { self.holdOnce = holdOnce; self.delay = delay }
    func instance() async throws -> ECSInstance {
        calls.append("instance")
        return ECSInstance(name: "test", status: "Running", os: "Linux", address: "10.0.0.1", cpu: 2, memoryMiB: 4096)
    }
    func monitor() async throws -> [ECSMonitorPoint] { calls.append("monitor"); return [] }
    func snapshot(mode: String, pid: Int?) async throws -> ECSSnapshot {
        calls.append(mode); active += 1; maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        if holdOnce.remove(mode) != nil {
            do { try await Task.sleep(for: .seconds(30)) }
            catch { cancelled.append(mode); throw error }
        }
        if delay { try await Task.sleep(for: .milliseconds(100)) }
        return try ECSSnapshot.decode(Data(#"{"version":1,"time":100}"#.utf8))
    }
}

@main struct ECSLoadingTests {
    @MainActor static func main() async throws {
        let connection = ECSConnection(name: "test", instanceID: "i-test", accessKeyID: "test-key", accessKeySecret: "test-secret")
        let initial = ECSMockReader()
        var configurationReads = 0
        let loaded = ECSStore(readConnection: { configurationReads += 1; return connection }, clientFactory: { _ in initial })
        // The initial refresh loads saved configuration itself, without requiring a
        // separate onAppear callback to run first or a manual pull to refresh.
        await loaded.refresh(.overview)
        precondition(configurationReads == 1 && loaded.overview != nil && !loaded.busy)
        let initialCalls = await initial.calls
        precondition(initialCalls == ["instance", "monitor", "overview"])
        await loaded.refresh(.processes)
        precondition(configurationReads == 1 && loaded.processes != nil)

        let switchingReader = ECSMockReader(holdOnce: ["overview"])
        let switching = ECSStore(connection: connection, clientFactory: { _ in switchingReader })
        let oldPage = Task { await switching.refresh(.overview) }
        await waitFor("overview", reader: switchingReader)
        await switching.refresh(.network)
        await oldPage.value
        let cancelled = await switchingReader.cancelled
        let maximum = await switchingReader.maximumActive
        precondition(cancelled == ["overview"] && maximum == 1)
        precondition(switching.overview == nil && switching.network != nil && !switching.busy && switching.error == nil)

        let returningReader = ECSMockReader(holdOnce: ["overview"])
        let returning = ECSStore(connection: connection, clientFactory: { _ in returningReader })
        let leaving = Task { await returning.refresh(.overview) }
        await waitFor("overview", reader: returningReader)
        leaving.cancel()
        // Return immediately, before the old request has reset its busy state.
        await returning.refresh(.overview)
        await leaving.value
        let returningCalls = await returningReader.calls
        precondition(returningCalls.filter { $0 == "overview" }.count == 2)
        precondition(returning.overview != nil && !returning.busy && returning.error == nil)

        let sharedReader = ECSMockReader(delay: true)
        let shared = ECSStore(connection: connection, clientFactory: { _ in sharedReader })
        async let automatic: Void = shared.refresh(.processes)
        async let manual: Void = shared.refresh(.processes)
        _ = await (automatic, manual)
        let sharedCalls = await sharedReader.calls
        precondition(sharedCalls.filter { $0 == "processes" }.count == 1 && shared.processes != nil)

        let missing = ECSStore(readConnection: { nil }, clientFactory: { _ in fatalError("No request without configuration") })
        await missing.refresh(.overview)
        precondition(missing.connection == nil && !missing.busy)
        let idleReader = ECSMockReader()
        let idle = ECSStore(connection: connection, clientFactory: { _ in idleReader })
        await idle.refresh(.terminal)
        let idleCalls = await idleReader.calls
        precondition(idleCalls.isEmpty)
        print("ECS initial load, page switching, immediate re-entry, request coalescing and cancellation checks passed")
    }

    @MainActor private static func waitFor(_ mode: String, reader: ECSMockReader) async {
        for _ in 0..<500 {
            if await reader.calls.contains(mode) { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        fatalError("Timed out waiting for mock snapshot")
    }
}
