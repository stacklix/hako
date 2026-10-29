import Foundation

private final class ArcaneLoadingProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private var pending: [String: [ArcaneLoadingProtocol]] = [:]
    private var holdsContainers = false

    func holdContainers(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        holdsContainers = value
    }

    func receive(_ request: ArcaneLoadingProtocol) {
        let path = request.request.url!.path
        lock.lock()
        requests.append(request.request)
        let automatic = path.hasSuffix("/environments") || path.hasSuffix("/activities") || (path.hasSuffix("/containers") && !holdsContainers)
            || path.hasSuffix("/projects") || path.hasSuffix("/projects/missing-env/compose") || path.hasSuffix("/projects/missing-env/workspace")
        if !automatic { pending[path, default: []].append(request) }
        lock.unlock()
        guard automatic else { return }
        if path.hasSuffix("/projects") {
            request.complete(#"{"success":true,"data":[{"id":"missing-env","name":"no-env","path":"/projects/no-env"}]}"#)
        } else if path.hasSuffix("/projects/missing-env/compose") {
            request.complete(#"{"success":true,"data":{"id":"missing-env","name":"no-env","composeContent":"services: {}","composeFileName":"compose.yaml"}}"#)
        } else if path.hasSuffix("/projects/missing-env/workspace") {
            request.complete(#"{"success":true,"data":{"files":[],"fileTreeRevision":"empty-tree","fileTreeTruncated":false}}"#)
        } else if path.hasSuffix("/environments") {
            request.complete(#"{"success":true,"data":[{"id":"0","name":"Local"},{"id":"remote","name":"Remote"}]}"#)
        } else if path.hasSuffix("/activities") {
            request.complete(#"{"success":true,"data":[]}"#)
        } else if path.hasSuffix("/containers") {
            let environment = path.contains("/remote/") ? "remote" : "0"
            request.complete("{\"success\":true,\"data\":[{\"id\":\"\(environment)-container\",\"state\":\"running\"}]}")
        }
    }

    func count(_ suffix: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return requests.filter { $0.url!.path.hasSuffix(suffix) }.count
    }

    func writeCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return requests.filter { $0.httpMethod != "GET" }.count
    }

    func complete(_ suffix: String, index: Int = 0, id: String, status: Int = 200, list: Bool = false, startedAt: String? = nil) {
        lock.lock()
        let matches = pending.first { $0.key.hasSuffix(suffix) }!.value
        let request = matches[index]
        lock.unlock()
        let startField = startedAt.map { ",\"startedAt\":\"\($0)\"" } ?? ""
        let data = list ? "[{\"id\":\"\(id)\",\"state\":\"running\"}]"
            : "{\"id\":\"\(id)\",\"name\":\"/\(id)\",\"state\":{\"status\":\"running\",\"running\":true\(startField)}}"
        request.complete("{\"success\":true,\"data\":\(data)}", status: status)
    }
}

private final class ArcaneLoadingProtocol: URLProtocol, @unchecked Sendable {
    static let probe = ArcaneLoadingProbe()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.probe.receive(self) }
    override func stopLoading() { }

    func complete(_ body: String, status: Int = 200) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@main @MainActor struct ArcaneLoadingTests {
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArcaneLoadingProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let connection = try ArcaneConnection(name: "Test", address: "https://arcane.example.com", apiKey: "test-key").normalized()
        let client = try ArcaneClient(connection: connection, session: session)
        let suiteName = "hako.arcane-loading-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var createdClients = 0
        let store = ArcaneStore(connection: connection, defaults: defaults) { _ in
            createdClients += 1
            return client
        }
        let firstClient = try store.client()
        let secondClient = try store.client()
        precondition(firstClient === secondClient && createdClients == 1, "Reuse the connection's client/session")

        let probe = ArcaneLoadingProtocol.probe
        await store.refresh()
        precondition(probe.count("/environments") == 1 && probe.count("/0/containers") == 1)
        precondition(store.environmentID == "0" && store.containers.first?.id == "0-container" && !store.loading)
        await store.refresh()
        precondition(probe.count("/environments") == 1 && probe.count("/0/containers") == 2,
                     "Polling must request containers directly after initial discovery")
        await store.refresh(forceEnvironments: true)
        precondition(probe.count("/environments") == 2 && probe.count("/0/containers") == 3)
        store.selectEnvironment("remote")
        await store.refresh()
        precondition(probe.count("/environments") == 2 && probe.count("/remote/containers") == 1)
        precondition(store.containers.first?.id == "remote-container" && createdClients == 1)

        let files = ArcaneFilesData()
        await files.load(client: client, environment: "remote", name: "no-env", workingDir: nil)
        precondition(files.error == nil && files.project?.envContent == nil && files.workspace?.files.isEmpty == true)
        let envFile = files.files.first { $0.kind == .env }!
        let editorSession = ArcaneFileEditorSession(environment: "remote", project: files.project!, initialFile: envFile)
        let editor = ArcaneFileEditorData()
        await editor.load(client: client, environment: editorSession.environment, project: editorSession.project, file: editorSession.initialFile)
        precondition(!editor.loading && editor.error == nil && editor.viewable && editor.editable && editor.draft.isEmpty && !editor.dirty,
                     "A missing .env must open as an empty editable document on the first load")
        await editor.save(store: store, environment: editorSession.environment, project: editorSession.project, file: editorSession.initialFile)
        precondition(probe.writeCount() == 0, "Opening a missing .env must never create it or write an empty file")
        await files.load(client: client, environment: "remote", name: "no-env", workingDir: nil)
        precondition(editorSession.initialFile.kind == .env && editor.viewable && editor.error == nil && !editor.loading,
                     "Reloading the directory must not replace the open editor's inputs")

        probe.holdContainers(true)
        let cancelledList = Task { await store.refresh() }
        try await waitFor("/remote/containers", count: 2)
        cancelledList.cancel()
        let resumedList = Task { await store.refresh() }
        try await waitFor("/remote/containers", count: 3)
        probe.complete("/remote/containers", index: 1, id: "resumed-list", list: true)
        await resumedList.value
        await cancelledList.value
        precondition(store.containers.first?.id == "resumed-list" && !store.loading && store.error == nil,
                     "Returning to the container list must not skip a load because a cancelled request is still unwinding")
        probe.holdContainers(false)

        let data = ArcaneContainerData()
        let old = Task { await data.refresh(client: client, environment: "0", container: "old") }
        try await waitFor("/containers/old")
        let new = Task { await data.refresh(client: client, environment: "0", container: "new") }
        try await waitFor("/containers/new")
        probe.complete("/containers/old", id: "old")
        let oldResult = await old.value
        precondition(oldResult == nil && data.loading && data.details == nil,
                     "An old completion must not clear the newer loading state")
        probe.complete("/containers/new", id: "new")
        let newResult = await new.value
        precondition(newResult?.id == "new" && data.details?.id == "new" && !data.loading)

        let cancelled = Task { await data.refresh(client: client, environment: "0", container: "cancelled") }
        try await waitFor("/containers/cancelled")
        cancelled.cancel()
        let resumed = Task { await data.refresh(client: client, environment: "0", container: "cancelled") }
        try await waitFor("/containers/cancelled", count: 2)
        probe.complete("/containers/cancelled", index: 1, id: "resumed")
        let resumedResult = await resumed.value
        _ = await cancelled.value
        precondition(resumedResult?.id == "resumed" && data.details?.id == "resumed" && data.error == nil && !data.loading,
                     "Returning to a cancelled load must start immediately, without waiting for the next poll")

        let staleFailure = Task { await data.refresh(client: client, environment: "0", container: "stale-failure") }
        try await waitFor("/containers/stale-failure")
        let latest = Task { await data.refresh(client: client, environment: "0", container: "latest") }
        try await waitFor("/containers/latest")
        probe.complete("/containers/latest", id: "latest")
        _ = await latest.value
        probe.complete("/containers/stale-failure", id: "unused", status: 403)
        _ = await staleFailure.value
        precondition(data.details?.id == "latest" && data.error == nil, "Stale errors must not replace newer data")

        let replaced = Task { await data.refresh(client: client, environment: "0", container: "replaced") }
        try await waitFor("/containers/replaced")
        data.reset()
        probe.complete("/containers/replaced", id: "replaced")
        _ = await replaced.value
        precondition(data.details == nil && !data.loading && data.error == nil, "A replacement must invalidate old requests")

        let target = try JSONDecoder().decode(ArcaneContainerDetails.self, from: Data(#"{"id":"operation-source","name":"/service","state":{"status":"running","running":true}}"#.utf8))
        let environment = store.environment!
        store.start(.redeploy, container: target, environment: environment)
        precondition(store.operationStatus(environmentID: "remote", containerID: target.id)?.text == "更新中…")
        precondition(store.operationStatus(environmentID: "0", containerID: target.id) == nil)
        precondition(store.operationStatus(environmentID: "remote", containerID: "other-container") == nil)
        try await waitFor("/operation-source/redeploy")
        probe.holdContainers(true)
        probe.complete("/operation-source/redeploy", id: "operation-replacement")
        try await waitFor("/remote/containers", count: 4)
        precondition(store.pending == nil && store.operationRunning)
        precondition(store.operationStatus(environmentID: "remote", containerID: "operation-replacement")?.running == true,
                     "Operation status must follow the replacement ID until the list refresh finishes")
        probe.complete("/remote/containers", index: 2, id: "operation-replacement", list: true)
        try await waitForCompletion(store)
        precondition(store.operationStatus(environmentID: "remote", containerID: "operation-replacement") == nil)
        probe.holdContainers(false)

        store.start(.redeploy, container: target, environment: environment)
        precondition(store.operationStatus(environmentID: "remote", containerID: "operation-replacement") == nil,
                     "A prior operation's replacement ID must not be attached to a new operation")
        try await waitFor("/operation-source/redeploy", count: 2)
        probe.complete("/operation-source/redeploy", index: 1, id: "unused", status: 500)
        try await waitForCompletion(store)
        precondition(store.operationStatus(environmentID: "remote", containerID: target.id)?.text == "更新结果待确认",
                     "An uncertain outcome must not keep displaying an active update")
        store.acknowledgeUnknownOperation()
        precondition(store.operationStatus(environmentID: "remote", containerID: target.id) == nil)
        let restartTarget = try JSONDecoder().decode(ArcaneContainerDetails.self, from: Data(#"{"id":"restart-source","name":"/service","state":{"status":"running","running":true,"startedAt":"2026-10-29T16:00:00Z"}}"#.utf8))
        store.start(.restart, container: restartTarget, environment: environment)
        try await waitFor("/restart-source/restart")
        probe.complete("/restart-source/restart", id: "unused", status: 500)
        try await waitForCompletion(store)
        try await waitFor("/containers/restart-source")
        precondition(store.verifyingOperation && store.pending?.previousStartedAt == "2026-10-29T16:00:00Z")
        let persisted = try JSONDecoder().decode(ArcanePendingOperation.self, from: defaults.data(forKey: "arcane.pending-operation")!)
        precondition(persisted.previousStartedAt == restartTarget.state?.startedAt)
        probe.complete("/containers/restart-source", id: "restart-source", startedAt: "2026-10-29T16:00:00Z")
        try await waitForVerification(store)
        precondition(store.pending != nil, "An unchanged running container must not clear an uncertain restart")
        let writesBeforeVerification = probe.writeCount()
        await store.refresh()
        try await waitFor("/containers/restart-source", count: 2)
        probe.complete("/containers/restart-source", index: 1, id: "restart-source", startedAt: "2026-10-29T17:00:00.123456789Z")
        try await waitForVerification(store)
        precondition(store.pending == nil && defaults.data(forKey: "arcane.pending-operation") == nil)
        precondition(store.operationStatus(environmentID: "remote", containerID: restartTarget.id) == nil)
        precondition(probe.writeCount() == writesBeforeVerification, "Verification must only read status; never repeat the restart")
        print("PASS: Arcane session reuse, polling, missing .env first load without writes, editor snapshots, cancellation, stale response isolation and scoped operation lifecycle status")
    }

    private static func waitFor(_ suffix: String, count: Int = 1) async throws {
        for _ in 0..<500 {
            if ArcaneLoadingProtocol.probe.count(suffix) >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        fatalError("Request did not start: \(suffix)")
    }

    private static func waitForCompletion(_ store: ArcaneStore) async throws {
        for _ in 0..<500 {
            if !store.operationRunning { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        fatalError("Operation did not finish")
    }

    private static func waitForVerification(_ store: ArcaneStore) async throws {
        for _ in 0..<500 {
            if !store.verifyingOperation { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        fatalError("Restart verification did not finish")
    }
}
