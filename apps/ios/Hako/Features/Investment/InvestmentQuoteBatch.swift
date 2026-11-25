import Foundation

/// Network waits overlap; callers collect results before publishing one ledger update.
enum InvestmentQuoteBatch {
    @MainActor
    static func map<Input: Sendable, Output: Sendable>(
        _ inputs: [Input], limit: Int = 3,
        channel: @MainActor @Sendable (Input) -> String = { _ in "default" },
        operation: @escaping @MainActor @Sendable (Input) async throws -> Output
    ) async throws -> [Output] {
        precondition(limit > 0)
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: (Int, Output).self) { group in
            let channels = inputs.map(channel)
            let queues = Dictionary(grouping: inputs.indices, by: { channels[$0] })
            var next: [String: Int] = [:]
            var results: [Int: Output] = [:]
            func enqueue(_ index: Int) {
                let input = inputs[index]
                group.addTask {
                    try Task.checkCancellation()
                    let value = try await operation(input)
                    try Task.checkCancellation()
                    return (index, value)
                }
            }
            for (key, indices) in queues {
                for index in indices.prefix(limit) { enqueue(index) }
                next[key] = min(limit, indices.count)
            }
            while let (index, value) = try await group.next() {
                try Task.checkCancellation()
                results[index] = value
                let key = channels[index]
                if let position = next[key], let indices = queues[key], position < indices.count {
                    enqueue(indices[position]); next[key] = position + 1
                }
            }
            return inputs.indices.map { results[$0]! }
        }
    }
}
