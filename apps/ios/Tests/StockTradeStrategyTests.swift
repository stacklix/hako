import Foundation

@main struct StockTradeStrategyTests {
    static func main() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let configuration = try JSONDecoder().decode(StockTradeStrategyConfiguration.self, from: data)
        precondition(configuration.valid && configuration.settings.includeMainBoard && configuration.settings.recommendationCount == 3)
        precondition(configuration.settings.boardSummary.contains("创业板"))
        var bad = configuration.settings
        bad.zxPeriods = [14, 14, 57, 114]; precondition(!bad.valid)
        bad = configuration.settings; bad.minScore = .nan; precondition(!bad.valid)
        bad = configuration.settings; bad.liquidityCount = 0; precondition(!bad.valid)
        bad = configuration.settings; bad.minMarketScore = 1.1; precondition(!bad.valid)
        bad = configuration.settings; bad.includeMainBoard = false; bad.includeGrowthBoard = false
        bad.includeStarBoard = false; bad.includeBeijing = false; precondition(!bad.valid)
        let encoded = try JSONEncoder().encode(configuration)
        let roundTrip = try JSONDecoder().decode(StockTradeStrategyConfiguration.self, from: encoded)
        precondition(roundTrip == configuration)
        print("Cerno strategy decoding, bounds, invalid numeric input and roundtrip passed")
    }
}
