import Foundation

struct QinglongAgentConversation: Codable {
    struct Operation: Codable, Identifiable {
        enum State: String, Codable {
            case pending, submitting, accepted, failed, discarded, expired, unverified, superseded
            var title: String {
                switch self {
                case .pending: "待确认"
                case .submitting: "正在提交"
                case .accepted: "请求已接受"
                case .failed: "提交失败"
                case .discarded: "已放弃"
                case .expired: "预览已过期"
                case .unverified: "结果未确认"
                case .superseded: "已被新草稿替换"
                }
            }
        }
        private(set) var proposal: QinglongAgentProposal
        let panelName: String
        private(set) var state: State = .pending
        private(set) var result: String?
        var id: UUID { proposal.id }

        @discardableResult
        mutating func begin() -> Bool {
            guard state == .pending else { return false }
            state = .submitting
            return true
        }
        @discardableResult
        mutating func finish(_ state: State, result: String) -> Bool {
            let allowed = self.state == .submitting && [.accepted, .failed, .unverified].contains(state)
                || self.state == .pending && [.discarded, .superseded].contains(state)
            guard allowed else { return false }
            self.state = state; self.result = result
            return true
        }
        mutating func revise(_ draft: QinglongAgentProposal) -> Bool {
            guard state == .pending, draft.id == proposal.id else { return false }
            proposal = draft; return true
        }
        mutating func restore(active: QinglongAgentProposal? = nil) {
            if state == .pending, let active, active.id == id { proposal = active }
            else if state == .pending {
                state = .expired
                result = "预览已过期，请重新生成并核对后确认。"
            } else if state == .submitting {
                state = .unverified
                result = "上次操作结果未确认，请先核对面板状态；不会自动重试。"
            }
        }
    }

    struct Message: Identifiable, Codable {
        var id = UUID()
        let text: String
        let isUser: Bool
        var images: [Data] = []
        var html: AssistantHTML?
        var operation: Operation?
    }
    let messages: [Message]
    let history: Data
    let modelKey: String?
    let format: LanguageModelFormat?
    let proposal: QinglongAgentProposal?
    let commitStarted: Bool

    static let writingPrinciples = """
        先查后问：读取真实面板和目标信息后，将缺少或有歧义的必要信息集中在一条回复中询问，使用页面字段名称。不要重复询问已明确的信息，选填内容不阻塞。
        草稿可讨论：有待确认草稿时仍可回答问题。用户修改当前草稿时带上当前 draft_id，保留未要求改变的字段，生成完整新预览；工具会合并同一操作中省略的草稿字段。新操作不带 draft_id。只解释不替换草稿，不把未提交草稿当作面板现状。
        表单一致：新增、编辑按页面字段展示，用户也可以点修改在原生表单中调整。删除、运行、停止、启用和禁用展示目标及确认操作，不生成无关编辑表单。
        确认后提交：模型不能提交，只有用户点击卡片确认才执行。生成草稿不等于已修改。结果不确定时先查询，不重复执行写操作；运行请求被接受不代表任务已完成。
        """
    static func draftContext(_ proposal: QinglongAgentProposal?) throws -> String {
        guard let proposal else { return "当前没有待确认草稿。旧卡片可能已提交、放弃或被替换，以最新面板状态为准。" }
        var fields = proposal.action.fields
        if fields["value"] != nil { fields["value"] = "[草稿已填写；未要求修改时省略该字段，不复制此占位文字]" }
        let data = try QinglongAgentTools.json(["draft_id": proposal.id.uuidString, "resource": proposal.action.resource.rawValue, "operation": proposal.action.kind.rawValue,
                                               "id": proposal.action.itemID ?? "", "fields": fields])
        return "当前待确认草稿（尚未提交，包含应用内手动修改）：\(proposal.title)。\n\(data)"
    }
}

typealias QinglongAgentStream = AssistantStream<QinglongAgentConversation.Message>
typealias QinglongAgentConversationFile = AssistantConversationFiles<QinglongAgentConversation, QinglongAgentToolCall>

extension QinglongAgentConversation.Message: AssistantReplyMessage {
    init(replyID: UUID, text: String, html: AssistantHTML?) {
        self.init(id: replyID, text: text, isUser: false, html: html)
    }
}

extension AssistantConversationFiles where Conversation == QinglongAgentConversation, Tool == QinglongAgentToolCall {
    init(connectionID: String) throws {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
        let name = Data(connectionID.utf8).map { String(format: "%02x", $0) }.joined()
        self.init(url: directory.appendingPathComponent("QinglongAssistant", isDirectory: true).appendingPathComponent(name + ".plist"))
    }
}
