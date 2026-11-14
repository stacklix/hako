import Foundation

typealias InvestmentAgentToolCall = AssistantToolCall<InvestmentAgentToolPresentation>

enum InvestmentAgentToolPresentation: AssistantToolPresentation {
    typealias Record = InvestmentAgentToolCall
    static func title(_ name: String) -> String {
        switch name {
        case "read_ledger": "查询账本"
        case "search_instruments": "搜索标的与合约"
        case "inspect_entry_form": "核对表单"
        case "propose_changes": "生成记账草稿"
        case "offer_ledger_export": "准备账本导出"
        default: "调用工具"
        }
    }

    static func icon(_ name: String) -> String {
        switch name {
        case "read_ledger": "externaldrive"
        case "search_instruments": "magnifyingglass"
        case "inspect_entry_form": "checklist"
        case "propose_changes": "doc.badge.plus"
        case "offer_ledger_export": "square.and.arrow.up"
        default: "wrench.and.screwdriver"
        }
    }

    static func summary(_ record: Record) -> String {
        let payload = record.payload, inputs = record.inputs
        if let summary = payload["summary"] as? String, payload["status"] as? String == "pending_user_confirmation" {
            return "已生成草稿 · " + summary
        }
        let preferred = ["查询范围", "搜索关键词", "标的", "交易所", "账户", "记账日期"]
        let values = preferred.compactMap { key in inputs.first { $0.label == key }?.value }
        return values.isEmpty ? inputs.first?.value ?? record.name : values.prefix(3).joined(separator: " · ")
    }

    static func outputs(_ record: Record) -> [AssistantToolField] {
        let payload = record.payload
        if payload["status"] as? String == "pending_user_confirmation" {
            return [.init(label: "生成结果", value: payload["summary"] as? String ?? "已生成草稿"),
                    .init(label: "调用结束时", value: "草稿待确认，尚未写入账本。")]
        }
        if payload["status"] as? String == "export_available_in_app" {
            return [.init(label: "执行结果", value: "已显示导出入口，点击后才会导出账本。")]
        }
        let forms = payload["forms"] as? [[String: Any]] ?? []
        if !forms.isEmpty {
            var fields: [AssistantToolField] = []
            for form in forms {
                let operation = form["operation"] as? String ?? "表单"
                if let missing = form["missing"] as? [String], !missing.isEmpty {
                    fields.append(.init(label: operation + " · 当时缺少的参数", value: missing.joined(separator: "、")))
                }
                if let error = form["validation_error"] as? String, !error.isEmpty {
                    fields.append(.init(label: operation + " · 校验问题", value: error))
                }
            }
            return fields.isEmpty ? [.init(label: "校验结果", value: "表单检查通过，资料完整。")] : fields
        }
        if let rows = payload["rows"] as? [[String: Any]] {
            var fields = [AssistantToolField(label: "本次返回", value: "\(rows.count) 条记录")]
            if let total = payload["total"] as? Int { fields.append(.init(label: "匹配总数", value: "\(total) 条")) }
            let names = rows.prefix(5).compactMap { row in
                row["display_code"] as? String ?? row["display_name"] as? String ?? row["name"] as? String ?? row["symbol"] as? String
            }
            if !names.isEmpty { fields.append(.init(label: rows.count > 5 ? "前 5 条记录" : "返回记录", value: names.joined(separator: "\n"))) }
            if payload["next_offset"] != nil { fields.append(.init(label: "后续数据", value: "还有更多记录，原始结果包含下一页位置。")) }
            return fields
        }
        return [.init(label: "执行结果", value: "工具已返回，完整内容可在原始结果中查看。")]
    }

    static func resultState(_ payload: [String: Any]) -> AssistantToolState {
        if payload["error"] != nil { return .failed }
        let forms = payload["forms"] as? [[String: Any]] ?? []
        if payload["status"] as? String == "needs_clarification" || forms.contains(where: {
            $0["validation_error"] != nil || ($0["missing"] as? [String])?.isEmpty == false
        }) { return .needsClarification }
        return .succeeded
    }
    static func clarificationTitle(_ payload: [String: Any]) -> String {
        let errors = (payload["forms"] as? [[String: Any]] ?? []).compactMap { $0["validation_error"] as? String }.filter { !$0.isEmpty }
        return errors.isEmpty ? "参数待完善" : "校验未通过"
    }

    static func resolves(_ earlier: Record, with later: Record) -> Bool {
        guard ["inspect_entry_form", "propose_changes"].contains(earlier.name),
              ["inspect_entry_form", "propose_changes"].contains(later.name),
              let before = (AssistantToolJSON.decode(earlier.arguments) as? [String: Any])?["actions"] as? [[String: Any]],
              let after = (AssistantToolJSON.decode(later.arguments) as? [String: Any])?["actions"] as? [[String: Any]],
              !before.isEmpty else { return false }
        let identities = ["account_id", "asset_id", "balance_account_id", "event_id", "record_id", "plan_id", "code", "name"]
        var remaining = after
        for action in before {
            guard let kind = action["action"] as? String,
                  identities.contains(where: { (action[$0] as? String)?.isEmpty == false }),
                  let index = remaining.firstIndex(where: { candidate in
                      candidate["action"] as? String == kind && AssistantToolJSON.contains(action, in: candidate)
                  }) else { return false }
            remaining.remove(at: index)
        }
        return true
    }
}

extension AssistantToolCall where Presentation == InvestmentAgentToolPresentation {
    init(call: LanguageModelCall, book: InvestmentBook, at date: Date = .now) {
        self.init(call: call, inputs: Self.describe(call.arguments ?? [:], book: book), at: date)
    }
    var message: InvestmentAgentConversation.Message {
        .init(id: id, text: title + " · " + statusTitle + "\n" + summary, isUser: false)
    }
    @MainActor
    static func perform(_ call: LanguageModelCall, book: InvestmentBook,
                        update: (Self) -> Void, operation: () async throws -> String) async throws -> String {
        try await perform(Self(call: call, book: book), update: update, operation: operation)
    }
    private static func describe(_ args: [String: Any], book: InvestmentBook) -> [Field] {
        var fields: [Field] = []
        func append(_ label: String, _ value: String?) {
            if let value, !value.isEmpty { fields.append(.init(label: label, value: value)) }
        }
        func account(_ value: String?) -> String? {
            guard let value else { return nil }
            guard let id = UUID(uuidString: value) else { return value }
            return book.account(id)?.name ?? book.balanceSheet?.accounts.first { $0.id == id }?.name ?? value
        }
        func asset(_ value: String?) -> String? {
            guard let value else { return nil }
            let match = UUID(uuidString: value).flatMap(book.asset)
                ?? book.assets.values.first { $0.code == value || $0.displayCode == value }
            return match.map { $0.displayName + " · " + $0.displayCode } ?? value
        }
        if let section = args["section"] as? String {
            append("查询范围", ["overview": "投资账户汇总", "holdings": "持仓", "balance": "资产负债汇总"][section]
                ?? InvestmentAgentProposal.sections.first { $0.name == section }?.title ?? section)
        }
        append("搜索关键词", args["query"] as? String)
        append("账户", account(args["account_id"] as? String))
        append("标的", asset(args["asset_id"] as? String))
        if let id = args["id"] as? String { append("查询记录", (args["section"] as? String == "investment_assets" ? asset(id) : id)) }
        append("交易所", args["market"] as? String)
        if let kind = args["asset_type"] as? String { append("标的类型", InvestmentAgentAction.assetKinds[kind]?.title ?? kind) }
        if let basis = args["basis"] as? String { append("合约本位", InvestmentAgentAction.bases[basis]?.rawValue ?? basis) }
        append("币种", args["currency"] as? String)
        if let stockConnect = args["stock_connect"] as? Bool { append("沪深港通", stockConnect ? "是" : "否") }
        append("起始日期", args["from"] as? String)
        append("截止日期", args["through"] as? String)
        if let limit = args["limit"] as? Int { append("最多返回", "\(limit) 条") }
        if let offset = args["offset"] as? Int { append("起始位置", String(offset)) }
        for (index, action) in (args["actions"] as? [[String: Any]] ?? []).enumerated() {
            let kind = (action["action"] as? String).flatMap(InvestmentAgentAction.Kind.init(rawValue:))
            let values = [kind?.title ?? action["action"] as? String, account(action["account_id"] as? String),
                          asset(action["asset_id"] as? String) ?? action["symbol"] as? String ?? action["name"] as? String,
                          action["date"] as? String].compactMap { $0 }
            append("操作 \(index + 1)", values.joined(separator: " · "))
        }
        return fields
    }
}
