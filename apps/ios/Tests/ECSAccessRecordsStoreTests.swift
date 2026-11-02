import Foundation

@MainActor final class RecordsClientMock: ECSAccessRecordsReading {
    var requestContext = "account-a"
    var queries: [String] = []
    var replies: [CheckedContinuation<ECSAccessRecords, Error>] = []
    func accessRecords(query: String) async throws -> ECSAccessRecords {
        queries.append(query)
        return try await withCheckedThrowingContinuation { replies.append($0) }
    }
}

@main struct ECSAccessRecordsStoreTests {
    @MainActor static func waitFor(_ predicate: () -> Bool) async {
        for _ in 0..<1000 {
            if predicate() { return }
            await Task.yield()
        }
        preconditionFailure("Expected asynchronous query state")
    }

    @MainActor static func main() async throws {
        let client = RecordsClientMock()
        let store = ECSAccessRecordsStore(client: client)
        let row = ECSAccessRecord(time: "2026-11-02T00:00:00Z", domain: "a.test", status: 404,
                                  ip: "192.0.2.1", path: "/a+b", userAgent: "UA", count: 2)
        func response(offset: Int, more: Bool, path: String = "/a+b") -> ECSAccessRecords {
            ECSAccessRecords(from: "2026-11-02T00:00:00+00:00", to: "2026-11-02T01:00:00+00:00", timezone: "UTC",
                             rows: [ECSAccessRecord(time: row.time, domain: row.domain, status: row.status,
                                                    ip: row.ip, path: path, userAgent: row.userAgent, count: row.count)],
                             totalRows: 2, requests: 4, offset: offset, limit: 1, hasMore: more)
        }
        let filter = ECSAccessRecordFilter(domain: "a.test", path: "/a+b", status: "404",
                                           from: Date(timeIntervalSince1970: 1793577599), to: Date(timeIntervalSince1970: 1793581200))
        try store.search(filter)
        await waitFor { client.replies.count == 1 }
        client.replies[0].resume(returning: response(offset: 0, more: true))
        await waitFor { !store.busy }
        precondition(store.rows.count == 1 && store.filter?.from == ECSAccessDate.parse("2026-11-02T00:00:00Z"))
        store.loadMore(); store.loadMore()
        await waitFor { client.replies.count == 2 }
        let query = URLComponents(string: "?" + client.queries[1])!.queryItems!
        precondition(query.first { $0.name == "offset" }?.value == "1")
        precondition(query.first { $0.name == "from" }?.value == "2026-11-02T00:00:00Z")
        precondition(query.first { $0.name == "path" }?.value == "/a+b")
        client.replies[1].resume(throwing: ECSAccessRecordsQuery.ValidationError(message: "offline"))
        await waitFor { !store.busy }
        precondition(store.rows.count == 1 && store.error == "offline")
        store.retry()
        await waitFor { client.replies.count == 3 }
        precondition(client.queries[1] == client.queries[2])
        client.replies[2].resume(returning: response(offset: 1, more: false, path: "/next"))
        await waitFor { !store.busy }
        precondition(store.rows.count == 2 && store.page?.hasMore == false)

        // A new search supersedes an in-flight search even if the old transport ignores cancellation.
        try store.search(filter)
        await waitFor { client.replies.count == 4 }
        try store.search(filter.continuing(row, by: .ip))
        await waitFor { client.replies.count == 5 }
        client.replies[4].resume(returning: response(offset: 0, more: false, path: "/new"))
        await waitFor { !store.busy }
        client.replies[3].resume(returning: response(offset: 0, more: false, path: "/stale"))
        for _ in 0..<20 { await Task.yield() }
        precondition(store.rows.first?.path == "/new")
        precondition(store.filter?.ip == row.ip && store.filter?.path == "" && store.filter?.status == "")

        try store.search(filter)
        await waitFor { client.replies.count == 6 }
        client.requestContext = "account-b"; store.clear()
        client.replies[5].resume(returning: response(offset: 0, more: false))
        for _ in 0..<20 { await Task.yield() }
        precondition(store.rows.isEmpty && store.page == nil && store.filter == nil && !store.busy)
        print("Access record pagination, retry, supersession and account isolation passed")
    }
}
