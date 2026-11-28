import Foundation

struct StockTradeStrategySettings: Codable, Equatable, Sendable {
    var includeMainBoard, includeGrowthBoard, includeStarBoard, includeBeijing: Bool
    var excludeST, excludeSuspended: Bool
    var minListingDays, liquidityCount, turnoverDays: Int
    var b1Enabled: Bool
    var jThreshold, jQuantile: Double
    var zxPeriods: [Int]
    var minScore, minRankScore, minMarketScore, maxRiskScore: Double
    var recommendationCount: Int
    var boardSummary: String {
        [(includeMainBoard, "主板"), (includeGrowthBoard, "创业板"), (includeStarBoard, "科创板"), (includeBeijing, "北交所")]
            .filter(\.0).map(\.1).joined(separator: " · ")
    }
    var valid: Bool {
        !boardSummary.isEmpty && (0...1000).contains(minListingDays) && (1...6000).contains(liquidityCount)
        && (1...250).contains(turnoverDays) && jThreshold.isFinite && (-100...100).contains(jThreshold)
        && jQuantile.isFinite && (0...1).contains(jQuantile) && zxPeriods.count == 4
        && zxPeriods.allSatisfy { (1...500).contains($0) } && zip(zxPeriods, zxPeriods.dropFirst()).allSatisfy { $0 < $1 }
        && minScore.isFinite && (0...5).contains(minScore) && minRankScore.isFinite && (0...100).contains(minRankScore)
        && minMarketScore.isFinite && (0...1).contains(minMarketScore) && maxRiskScore.isFinite && (0...100).contains(maxRiskScore)
        && (1...20).contains(recommendationCount)
    }
}

struct StockTradeStrategyConfiguration: Codable, Equatable, Sendable {
    let revision: String
    let settings: StockTradeStrategySettings
    let updatedAt: String?
    var valid: Bool { revision.count == 64 && revision.allSatisfy { $0.isHexDigit && !$0.isUppercase } && settings.valid }
}
