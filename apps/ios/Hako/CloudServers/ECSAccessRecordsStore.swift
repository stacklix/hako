import Foundation
import Combine

@MainActor protocol ECSAccessRecordsReading: AnyObject {
    var requestContext: String { get }
    func accessRecords(query: String) async throws -> ECSAccessRecords
}

@MainActor final class ECSAccessRecordsStore: ObservableObject {
    @Published private(set) var rows: [ECSAccessRecord] = []
    @Published private(set) var page: ECSAccessRecords?
    @Published private(set) var filter: ECSAccessRecordFilter?
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    private let client: any ECSAccessRecordsReading
    private var task: Task<Void, Never>?
    private var ticket = UUID()

    init(client: any ECSAccessRecordsReading) { self.client = client }

    func search(_ filter: ECSAccessRecordFilter) throws {
        _ = try filter.query()
        cancel()
        self.filter = filter; rows = []; page = nil; error = nil
        fetch(filter, append: false)
    }

    func loadMore() {
        guard !busy, page?.hasMore == true, let filter else { return }
        fetch(filter, append: true)
    }

    func retry() {
        guard !busy, let filter else { return }
        fetch(filter, append: page != nil)
    }

    func cancel() {
        ticket = UUID(); task?.cancel(); task = nil; busy = false
    }

    func clear() {
        cancel(); rows = []; page = nil; filter = nil; error = nil
    }

    private func fetch(_ filter: ECSAccessRecordFilter, append: Bool) {
        let id = UUID(); ticket = id
        let context = client.requestContext
        let offset = append ? rows.count : 0
        busy = true; error = nil
        task = Task {
            defer { if ticket == id { busy = false; task = nil } }
            do {
                let result = try await client.accessRecords(query: filter.query(offset: offset))
                try Task.checkCancellation()
                guard ticket == id, context == client.requestContext else { return }
                guard result.offset == offset else {
                    throw ECSAccessRecordsQuery.ValidationError(message: "分页位置不一致，请重新查询。")
                }
                if append { rows += result.rows } else { rows = result.rows }
                self.filter = filter.fixedWindow(result)
                page = result
            } catch is CancellationError { }
            catch {
                if ticket == id, context == client.requestContext { self.error = error.localizedDescription }
            }
        }
    }
}
