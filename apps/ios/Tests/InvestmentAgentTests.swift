import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@main
struct InvestmentAgentTests {
    @MainActor
    static func main() throws {
        try proposedTransferIncludesBothSidesWithoutChangingBook()
        try proposalRetainsCashImpactAndAutomaticallyAddedDeposit()
        try rejectsMalformedModelArguments()
        try modelWireFormatsRoundTripToolCallsAndImages()
        try anthropicMessagesUsesVersionAfterGatewayPrefix()
        sanitizesModelHTML()
        try savesConversationAndPendingProposal()
        try persistsModelSelection()
        print("Investment agent tests passed")
    }

    private static func savesConversationAndPendingProposal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = InvestmentAgentConversationFile(url: directory.appendingPathComponent("account.plist"))
        let other = InvestmentAgentConversationFile(url: directory.appendingPathComponent("other.plist"))
        let empty = try file.load()
        precondition(empty == nil)
        let proposal = try InvestmentAgentProposal(base: snapshot(InvestmentBook()), actions: [
            .init(kind: .addAccount, values: ["name": "测试账户", "currency": "CNY", "account_type": "securities"])
        ])
        let messages: [InvestmentAgentConversation.Message] = [
            .init(text: "成交截图", isUser: true, images: [Data([1, 2, 3]), Data([4, 5]), Data([6, 7, 8])]),
            .init(text: "", isUser: false, html: InvestmentAgentHTML("<p><strong>明细</strong></p>"))
        ]
        let history = Data("[[{\"role\":\"user\",\"content\":\"成交截图\"}]]".utf8)
        try file.save(.init(messages: messages, history: history, modelKey: "test", format: .openAI,
                            proposal: proposal, canExport: false, commitStarted: true))
        guard let saved = try file.load(), let draft = saved.proposal else { preconditionFailure("Missing saved conversation") }
        precondition(saved.messages.map(\.id) == messages.map(\.id) && saved.messages[0].images == messages[0].images)
        precondition(saved.messages[1].images.isEmpty)
        precondition(saved.messages[1].html?.fragment == "<p><strong>明细</strong></p>")
        precondition(saved.history == history && saved.commitStarted)
        let newSession = UUID()
        let restored = draft.restored(for: newSession)
        precondition(restored.id == proposal.id && restored.session == newSession && restored.generation == proposal.generation)
        precondition(restored.book.accounts.first?.name == "测试账户" && restored.changes.count == 1)
        let isolated = try other.load()
        precondition(isolated == nil)
        try file.remove()
        try file.remove()
        let removed = try file.load()
        precondition(removed == nil)
    }

    private static func sanitizesModelHTML() {
        let response = """
        <!doctype html><!-- comment --><SECTION style="color:red" onclick="attack()"><h2>资产总额</h2><p><strong>125,000.25 CNY</strong></p>
        <dl><dt>净资产</dt><dd>99,999.75 CNY</dd></dl><table><tr><th>账户</th><td>现金</td></tr></table>
        <script>attack()</script><svg><style>hidden</style></svg><img src="https://example.test/image">
        <ul><li><a href="https://example.test">明细</a></li></ul></SECTION>
        """
        let expected = """
        <section><h2>资产总额</h2><p><strong>125,000.25 CNY</strong></p>
        <dl><dt>净资产</dt><dd>99,999.75 CNY</dd></dl><table><tr><th>账户</th><td>现金</td></tr></table>

        <ul><li>明细</li></ul></section>
        """
        precondition(InvestmentAgentHTML(response)?.fragment == expected)
        precondition(InvestmentAgentHTML("```html\r\n<p>1 < 2 &amp; &lt;img&gt;</p>\r\n```")?.fragment ==
                     "<p>1 &lt; 2 &amp; &lt;img&gt;</p>")
        precondition(InvestmentAgentHTML("<script>attack()</script><p> </p>") == nil)
        precondition(InvestmentAgentHTML(String(repeating: "a", count: 128_001)) == nil)
    }

    private static func anthropicMessagesUsesVersionAfterGatewayPrefix() throws {
        for suffix in ["/coding/", "/coding/v1", "/coding/v1/messages"] {
            let configuration = LanguageModelConfiguration(format: .anthropic, baseURL: "https://gateway.example" + suffix,
                                                           model: "example", token: "test")
            let endpoint = try configuration.endpoint()
            precondition(endpoint.path == "/coding/v1/messages")
        }
    }

    private final class MemorySecrets: SecretStorage {
        var data: [String: Data] = [:]
        func read(account: String) throws -> Data? { data[account] }
        func save(_ value: Data, account: String, accessibility: SecretAccessibility) throws { data[account] = value }
        func delete(account: String) throws { data.removeValue(forKey: account) }
        func accounts() throws -> [String] { Array(data.keys) }
    }

    @MainActor
    private static func persistsModelSelection() throws {
        let secrets = MemorySecrets()
        let first = LanguageModelProfile(name: "First", configuration: .init(model: "first-model", token: "first-token"))
        let initial = try LanguageModelProfiles.update(using: secrets) { try $0.upsert(first) }
        precondition(initial.active == first)

        let second = LanguageModelProfile(name: "Second", configuration: .init(format: .anthropic,
            baseURL: "https://api.anthropic.com/v1", model: "second-model", token: "second-token"))
        let added = try LanguageModelProfiles.update(using: secrets) { try $0.upsert(second) }
        precondition(added.entries.count == 2 && added.active == first)
        try LanguageModelProfiles.update(using: secrets) { try $0.select(second.id) }
        let selected = try LanguageModelProfiles.load(using: secrets)
        precondition(selected.active == second)
        let removed = try LanguageModelProfiles.update(using: secrets) { $0.remove(second.id) }
        precondition(removed.active == first)
        try LanguageModelProfiles.update(using: secrets) { $0.remove(first.id) }
        let empty = try LanguageModelProfiles.load(using: secrets)
        precondition(empty.entries.isEmpty && empty.active == nil)
    }

    private static func snapshot(_ book: InvestmentBook) -> InvestmentAgentSnapshot {
        .init(book: book, session: UUID(), generation: 7, revision: 3, dirtyFrom: nil, tables: [:])
    }

    private static func proposedTransferIncludesBothSidesWithoutChangingBook() throws {
        var book = InvestmentBook()
        let source = InvestmentAccount(name: "美元账户", currency: .usd, type: .securities)
        let target = InvestmentAccount(name: "人民币账户", currency: .cny, type: .securities)
        book.accounts = [source, target]
        let day = InvestmentBook.day()
        try book.post(.init(day: day, kind: .deposit, amount: 100), accountID: source.id)
        let date = InvestmentBook.snapshotDateFormatter().string(from: day)
        let action = InvestmentAgentAction(kind: .transfer, values: [
            "account_id": source.id.uuidString, "target_id": target.id.uuidString,
            "date": date, "amount": "20.125", "received": "141.25"
        ])
        let base = snapshot(book)
        let preview = try InvestmentAgentProposal(base: base, actions: [action])
        precondition(preview.generation == base.generation && preview.session == base.session)
        precondition(preview.changes.count == 2 && preview.changes.allSatisfy { $0.operation == .add })
        precondition(preview.changes.flatMap(\.fields).contains { $0.id == "cash_change" && $0.after == "USD -20.125" })
        precondition(preview.changes.flatMap(\.fields).contains { $0.id == "cash_change" && $0.after == "CNY 141.25" })
        precondition(book.account(source.id)?.events.count == 1 && book.account(target.id)?.events.isEmpty == true)
        precondition(preview.book.account(target.id)?.events.first?.transferID == preview.book.account(source.id)?.events.last?.transferID)
    }

    private static func proposalRetainsCashImpactAndAutomaticallyAddedDeposit() throws {
        var book = InvestmentBook()
        let account = InvestmentAccount(name: "测试证券", currency: .usd, type: .securities)
        book.accounts = [account]
        let asset = InvestmentAsset(name: "Example", code: "TEST", market: "US", kind: .stock, currency: .usd)
        let assetID = try book.register(asset)
        let date = InvestmentBook.snapshotDateFormatter().string(from: InvestmentBook.day())
        let action = InvestmentAgentAction(kind: .addEvent, values: ["account_id": account.id.uuidString, "asset_id": assetID.uuidString,
            "date": date, "event_type": "buy", "quantity": "5", "price": "220.50", "fee": "1.25", "auto_fund": "true"])
        let preview = try InvestmentAgentProposal(base: snapshot(book), actions: [action])
        precondition(preview.changes.count == 2 && book.accounts[0].events.isEmpty)
        precondition(Set(preview.changes.flatMap(\.fields).filter { $0.id == "cash_change" }.compactMap(\.after)) == ["USD 1103.75", "USD -1103.75"])
    }

    private static func rejectsMalformedModelArguments() throws {
        let malformed: [[String: Any]] = [
            ["actions": [["action": "commit"]]],
            ["actions": [["action": "refresh_market", "unexpected": "1"]]],
            ["actions": [["action": "add_event", "date": "2026-11-10", "event_type": "buy"]]]
        ]
        for input in malformed {
            do { _ = try InvestmentAgentAction.parse(input); preconditionFailure("Invalid model operation was accepted") }
            catch is InvestmentError { continue }
        }
    }

    private static func modelWireFormatsRoundTripToolCallsAndImages() throws {
        for format in LanguageModelFormat.allCases {
            let client = LanguageModelClient(configuration: .init(format: format, baseURL: "https://gateway.example/v1", model: "example", token: "test"))
            let tool = LanguageModelTool(name: "probe", description: "Probe",
                                         properties: ["value": ["type": "string"]], required: ["value"])
            let images = [Data([0xFF, 0xD8, 0xFF]), Data([1, 2, 3]), Data([4, 5, 6])]
            let request = try client.request(system: "system", messages: [client.userMessage("images", images: images)], tools: [tool])
            guard let payload = request.httpBody,
                  let body = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  let messages = body["messages"] as? [[String: Any]],
                  let parts = messages.last?["content"] as? [[String: Any]] else {
                preconditionFailure("Missing image in request")
            }
            precondition(body["tool_choice"] == nil, "Tool calling should use the provider's default selection mode")
            precondition(parts.count == images.count + 1 && parts.first?["text"] as? String == "images")
            let response: [String: Any]
            switch format {
            case .openAI:
                precondition(request.url?.path == "/v1/chat/completions" && request.value(forHTTPHeaderField: "Authorization") == "Bearer test")
                let urls = parts.dropFirst().compactMap { ($0["image_url"] as? [String: String])?["url"] }
                precondition(urls == images.map { "data:image/jpeg;base64," + $0.base64EncodedString() })
                response = ["choices": [["message": ["role": "assistant", "content": NSNull(), "annotations": [],
                    "tool_calls": [["id": "call", "type": "function", "function": ["name": "probe", "arguments": #"{"value":"ping"}"#]]]]]]]
            case .anthropic:
                precondition(request.url?.path == "/v1/messages" && request.value(forHTTPHeaderField: "x-api-key") == "test")
                let sources = parts.dropFirst().compactMap { $0["source"] as? [String: String] }
                precondition(sources.allSatisfy { $0["media_type"] == "image/jpeg" })
                precondition(sources.compactMap { $0["data"] } == images.map { $0.base64EncodedString() })
                response = ["content": [["type": "tool_use", "name": "probe", "id": "call", "input": ["value": "ping"]]]]
            }
            let reply = try client.decode(JSONSerialization.data(withJSONObject: response))
            precondition(reply.calls.count == 1 && reply.calls[0].arguments?["value"] as? String == "ping")
            precondition(reply.message["annotations"] == nil)
            let result = client.toolMessages([(reply.calls[0], "ok")])
            if format == .openAI { precondition(result[0]["tool_call_id"] as? String == "call") }
            else { precondition((result[0]["content"] as? [[String: String]])?.first?["tool_use_id"] == "call") }
            let imageOnly = client.userMessage("", images: images)["content"] as? [[String: Any]]
            precondition(imageOnly?.count == images.count && imageOnly?.first?["type"] as? String != "text")
            let textOnly = client.userMessage("文字记账")
            if format == .openAI { precondition(textOnly["content"] as? String == "文字记账") }
            else { precondition((textOnly["content"] as? [[String: String]])?.first?["text"] == "文字记账") }
        }
    }
}
