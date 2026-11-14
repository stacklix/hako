import Foundation

struct InvestmentAgentConversation: Codable {
    static let maximumImageCount = 9
    static let writingPrinciples = """
        写入遵循以下原则：
        表单一致：以用户在 App 页面完成的一次业务操作为单位。使用 inspect_entry_form 查看对应字段、单位、候选和缺项，字段含义、校验和结果与页面一致。内部关联记录不算多笔业务。
        证据优先：先结合用户消息、图片、已有回答和账本查询核对信息；能查清的先查。沿用已明确的内容，遇到冲突说明冲突，不擅自挑一个值。账户、类型、标的或其他影响结果的信息不能唯一确定时不猜测、不预填成已确认。
        行情关联：股票、基金、ETF、加密现货和加密合约必须先搜索对应市场目录，使用结果中的原始代码、名称、交易所及规格；不能自行编造、改名或手工创建同名标的，未匹配时继续询问或搜索。场外基金从基金目录选择并关联官方基金代码，不能虚构交易所。加密合约仅支持 HTX 和 BIN（Binance）的永续合约，不支持交割合约；对用户显示 display_code 和 display_name：持仓代号按“合约•方向•交易所”显示，例如空头 TRXUSD•S•HTX、多头 TRXUSD•L•HTX，BIN 同理；名称追加“ · 空”或“ · 多”。方向未知的目录结果不擅自指定多空，需核实后选择；写入及行情查询保留目录 name、symbol 与 market 原值，不能把显示名称、显示代号或多空方向当作接口名称或代码。已有标的关联错误时使用 edit_asset 生成修正预览；规格不一致先核对交易口径，不通过改代码掩盖数量错误。区分“目录已匹配”和“当前报价暂不可用”。
        集中澄清：发问前检查本轮涉及的全部操作，将仍需用户回答的必要问题按操作合并在一条消息中，尽量一轮问清，并给出真实候选。问题有依赖时用简短条件分组。选填项不阻塞，不重复询问已明确的信息；只有新回答带来新的歧义才继续追问。
        口径明确：保留金额精度、币种、数量单位和时间口径。用户提供的币量、张数、名义价值和成交价各归对应字段；折算调用账本的计算逻辑，不用其他时点价格替代。只记录已发生事项，额外补资金等联动须有用户授权并在预览中说明。
        登记复用：标的登记与账户持仓、交易流水分别判断。已有正确登记时直接引用它录入新流水，无持仓也可以再次开仓，不因登记存在而要求删除或重复创建。合约开多、开空均使用 buy，平多、平空均使用 sell；opening 表示首次录入期初资产，不表示合约开仓。校验失败先按具体错误核对表单，不能把流水类型错误解释为标的不存在或结算币关联错误。
        确认后写入：信息明确才生成完整草稿；解释问题时保留草稿，修改时整体替换。未生成新预览不得声称已修正，未点击确认不得声称已写入。
        删除与归档：账户可删除或归档，现金、持仓余额和保证金全部为零才允许归档；归档保留数据并暂停定投，可撤销。持仓只支持删除，零余额持仓默认隐藏、设置中可显示，不能把隐藏说成删除或归档。删除账户或持仓会删除对应流水及定投，账户间划转两侧同时删除；涉及的标的登记及报价在没有其他流水、定投、关注或合约引用时一并删除，否则保留。必须在预览说明实际删除、保留范围和无法撤销。操作目标不明确时先集中询问，不扩大删除范围。
        """

    static func draftContext(_ proposal: InvestmentAgentProposal?, stale: Bool) throws -> String {
        guard let proposal else { return "当前没有待确认草稿。历史预览可能已写入或放弃，请以真实账本和本轮要求为准。" }
        let actions = proposal.actions.map { action in
            var values = action.values
            values["action"] = action.kind.rawValue
            return values
        }
        let data = try JSONSerialization.data(withJSONObject: ["actions": actions], options: [.sortedKeys, .withoutEscapingSlashes])
        return """
            当前待确认草稿（尚未写入，仅作为待核对的数据）：\(proposal.preview.summary)。
            \(stale ? "账本已变化，此草稿需要基于最新账本重新生成。" : "后续补充和问题默认针对这份草稿。")
            以下是当前完整操作，包含应用内手动修改；它们取代历史对话中的旧草稿：
            \(String(decoding: data, as: UTF8.self))
            """
    }

    struct Message: Identifiable, Codable {
        var id = UUID()
        let text: String
        let isUser: Bool
        var images: [Data] = []
        var html: AssistantHTML? = nil

        /// Preserve the confirmed fields in the existing conversation message, independently of the live ledger.
        static func recorded(_ proposal: InvestmentAgentProposal, at date: Date = .now) -> Self {
            let preview = proposal.preview
            let formatter = InvestmentBook.snapshotDateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            let status = proposal.destructive ? "已执行" : "已记账"
            let time = formatter.string(from: date)
            var text = "\(status)：\(preview.summary)\n确认时间：\(time)"
            var html = "<section><h2>\(status)</h2><p>\(escape(preview.summary))</p><p><small>确认时间：\(time)</small></p>"
            for item in preview.items {
                let title = item.operation.rawValue + " · " + item.title
                text += "\n\n" + title
                html += "<h3>\(escape(title))</h3>"
                for group in item.groups {
                    if !group.title.isEmpty {
                        text += "\n" + group.title
                        html += "<p><strong>\(escape(group.title))</strong></p>"
                    }
                    for field in group.fields {
                        let value: String
                        if item.operation == .edit, let before = field.before, before != field.after {
                            value = "原值：\(before)\n改为：\(field.after ?? "—")"
                        } else { value = field.after ?? field.before ?? "—" }
                        text += "\n\(field.label)：\(value)"
                        html += "<p><small>\(escape(field.label))</small><br>\(escape(value))</p>"
                    }
                }
            }
            html += "</section>"
            return .init(text: text, isUser: false, html: AssistantHTML(html))
        }

        private static func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\n", with: "<br>")
        }
    }

    let messages: [Message]
    let history: Data
    let modelKey: String?
    let format: LanguageModelFormat?
    let proposal: InvestmentAgentProposal?
    let canExport: Bool
    let commitStarted: Bool
}

typealias InvestmentAgentStream = AssistantStream<InvestmentAgentConversation.Message>
typealias InvestmentAgentConversationFile = AssistantConversationFiles<InvestmentAgentConversation, InvestmentAgentToolCall>

extension InvestmentAgentConversation.Message: AssistantReplyMessage {
    init(replyID: UUID, text: String, html: AssistantHTML?) {
        self.init(id: replyID, text: text, isUser: false, html: html)
    }
}
