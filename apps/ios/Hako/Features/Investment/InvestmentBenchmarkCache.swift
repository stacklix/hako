import Foundation

actor InvestmentBenchmarkCache {
    static let shared = InvestmentBenchmarkCache()
    private struct Entry {
        let checkedDay: Date
        let checkedAt: Date
        let start: Date
        let end: Date
        let quotes: [InvestmentQuote]
    }
    private var entries: [InvestmentBenchmark: Entry] = [:]

    func history(_ benchmark: InvestmentBenchmark, from start: Date, through end: Date, refresh: Bool = false) async throws -> [InvestmentQuote] {
        let today = InvestmentBook.day()
        // Include preceding sessions to establish a real closing-price baseline on holidays.
        let first = InvestmentBook.addDays(-10, to: start)
        if !refresh, let cached = entries[benchmark], cached.checkedDay == today,
           Date.now.timeIntervalSince(cached.checkedAt) < 300, cached.start <= first, cached.end >= end {
            return cached.quotes
        }
        let quotes = try await InvestmentQuoteProvider().benchmarkHistory(benchmark, from: first, through: end)
        try Task.checkCancellation()
        entries[benchmark] = .init(checkedDay: today, checkedAt: .now, start: first, end: end, quotes: quotes)
        return quotes
    }
}
