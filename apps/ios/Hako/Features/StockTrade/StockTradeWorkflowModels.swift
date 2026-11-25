import Foundation

enum StockTradeWorkflowKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case full, fetch, preselect, review, publish
    var id: String { rawValue }
    var title: String {
        switch self {
        case .full: "完整选股并发布"
        case .fetch: "更新行情"
        case .preselect: "执行初选"
        case .review: "逐票复评"
        case .publish: "发布已有结果"
        }
    }
    var phases: [String] { self == .full ? ["fetch", "preselect", "review", "publish"] : [rawValue] }
    var explanation: String {
        switch self {
        case .full: "更新行情、策略初选、逐票复评，完整性校验通过后自动发布。"
        case .fetch: "更新后台配置范围内的行情，不自动执行初选或发布。"
        case .preselect: "使用现有行情生成候选，不自动执行复评或发布。"
        case .review: "对当前候选逐票复评，不自动发布。"
        case .publish: "校验现有候选、复评和行情的完整性，通过后发布；失败时保留已发布结果。"
        }
    }
    static func phaseTitle(_ phase: String) -> String {
        ["pending": "等待执行", "fetch": "抓取行情", "preselect": "策略初选", "review": "逐票复评", "publish": "校验并发布"][phase] ?? phase
    }
}

struct StockTradePublishedRun: Decodable, Identifiable, Sendable {
    let runId, snapshotId, revision, dataAsOf, publishedAt, status: String
    var id: String { runId }
}

struct StockTradeWorkflowTask: Decodable, Identifiable, Sendable {
    enum State: String, Decodable, Sendable {
        case queued, running, succeeded, failed
        var title: String {
            switch self {
            case .queued: "排队中"
            case .running: "执行中"
            case .succeeded: "已完成"
            case .failed: "失败"
            }
        }
        var active: Bool { self == .queued || self == .running }
    }
    struct Event: Decodable, Identifiable, Sendable {
        let sequence: Int
        let at, message: String
        var id: Int { sequence }
    }
    let id: String
    let kind: StockTradeWorkflowKind
    let state: State
    let phase, createdAt: String
    let dataDate, startedAt, finishedAt, failureCode: String?
    let result: StockTradePublishedRun?
    let events: [Event]
    func validated() throws -> Self {
        guard id.count == 32, id.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              (["pending"] + kind.phases).contains(phase),
              events.count <= 100, Set(events.map(\.sequence)).count == events.count,
              events.allSatisfy({ $0.message.count <= 500 }),
              state != .succeeded || kind != .full && kind != .publish || result?.status == "complete"
        else { throw StockTradeFailure.invalidResponse }
        return self
    }
}

struct StockTradeWorkflowPage: Decodable, Sendable {
    let items: [StockTradeWorkflowTask]
    let nextCursor: String?
    let workerOnline: Bool
}
