import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@main
struct InvestmentAgentTests {
    @MainActor
    static func main() async throws {
        try proposedTransferIncludesBothSidesWithoutChangingBook()
        try proposalRetainsCashImpactAndAutomaticallyAddedDeposit()
        try contractPreviewUsesOneEntryForm()
        try existingContractRegistrationAcceptsNewTrades()
        try contractDetailEditsAndDeletesKeepTheirTransaction()
        try followUpReplacesUncommittedDraft()
        try incompleteContractRequiresClarification()
        try formInspectionCollectsMissingFieldsWithoutWriting()
        try coinEntryUsesPageQuantityConversions()
        try businessActionsGroupLinkedRecords()
        try cashBalanceUsesAdjustment()
        try editingEntriesKeepsPageSignAndClearingRules()
        try termDepositsAndPlansFollowPageForms()
        try snapshotPreviewIncludesFetchedInputs()
        try relinkingContractPreservesTheTrade()
        try catalogIdentityIsReadOnlyAndContractAliasesResolve()
        try lifecycleActionsUseOneBusinessPreview()
        try await nativeEditorOnlyRevisesThePendingDraft()
        try nativeEditorKeepsSharedRegistrationsAndOtherEntries()
        try nativeEditorUsesTheBalanceBeforeItsEntry()
        try nativeEditorPreservesPlanIdentityAndCanClearItsAsset()
        try nativeEditorKeepsOptionalValuationInTheSamePreview()
        try deletionPreviewsHaveNoEntryEditor()
        try await modelRetriesOnlyTheFailedRequest()
        try await modelRetriesAreBoundedAndCancellable()
        try streamingFramesAndToolsAreCompleteBeforeUse()
        streamingPresentationSurvivesToolsAndRetries()
        try savesToolRepliesAndInterruptedReplies()
        try await streamingProgressArrivesBeforeCompletion()
        try await truncatedStreamsRetryWithoutMixingContent()
        try await cancellingAStreamClosesItsTransport()
        try rejectsMalformedModelArguments()
        try modelWireFormatsRoundTripToolCallsAndImages()
        try anthropicMessagesUsesVersionAfterGatewayPrefix()
        sanitizesModelHTML()
        try savesConversationAndPendingProposal()
        try savesConfirmedPreviewWithoutAnActiveDraft()
        try savesComposerWithoutChangingTheConversation()
        try await recordsEveryToolAttemptAndItsOutcome()
        try await toolCancellationAndMalformedArgumentsRemainVisible()
        try savesToolRecordsWithoutChangingConversationFormat()
        try toolFollowUpsKeepTheOriginalCheck()
        try persistsModelSelection()
        try assertAssistantFileRoundTrip(InvestmentAgentConversationFile(url: URL(fileURLWithPath: "Tests/Fixtures/investment-assistant.plist")))
        print("Investment agent tests passed")
    }

    @MainActor
    private static func recordsEveryToolAttemptAndItsOutcome() async throws {
        let (base, _) = try contractDraft()
        let call = LanguageModelCall(id: "same-provider-id", name: "inspect_entry_form", arguments: ["actions": []])
        var updates: [InvestmentAgentToolCall] = []
        let ok = "{\"forms\":[{\"operation\":\"开空\",\"missing\":[]}]}"
        let missing = "{\"forms\":[{\"operation\":\"开空\",\"missing\":[\"账户\"]}]}"
        let invalid = "{\"forms\":[{\"operation\":\"首次录入\",\"missing\":[],\"validation_error\":\"开仓请选择开空\"}]}"
        for output in [ok, missing, invalid] {
            let result = try await InvestmentAgentToolCall.perform(call, book: base.book, update: { updates.append($0) }) {
                precondition(updates.last?.state == .running, "A real invocation must be visible before execution")
                return output
            }
            precondition(result == output, "Recording must not change the result sent back to the model")
        }
        precondition(updates.count == 6)
        precondition(Set(updates.map(\.id)).count == 3, "Repeated provider IDs are separate invocations")
        precondition(updates[0].id == updates[1].id && updates[2].id == updates[3].id)
        precondition(updates[1].state == .succeeded && updates[1].elapsed! >= 0)
        precondition(updates[3].state == .needsClarification && updates[3].statusTitle == "参数待完善")
        precondition(updates[5].state == .needsClarification && updates[5].statusTitle == "校验未通过")
        precondition(updates[5].outputs.contains { $0.value == "开仓请选择开空" })

        let proposal = LanguageModelCall(id: "draft", name: "propose_changes", arguments: ["actions": []])
        _ = try await InvestmentAgentToolCall.perform(proposal, book: base.book, update: { updates.append($0) }) {
            "{\"status\":\"pending_user_confirmation\",\"summary\":\"1 笔交易\"}"
        }
        let drafted = updates.last!
        precondition(drafted.state == .succeeded && drafted.summary == "已生成草稿 · 1 笔交易")
        precondition(drafted.outputs.contains { $0.value.contains("尚未写入") })
        precondition(!drafted.message.text.contains("已记账"))

        let failure = try await InvestmentAgentToolCall.perform(call, book: base.book, update: { updates.append($0) }) {
            throw InvestmentError.invalid("查询未完成")
        }
        precondition(updates.last?.state == .failed && updates.last?.result == failure)
        precondition(updates.last?.outputs.first?.value == "查询未完成")
        precondition(base.book.accounts[0].events.count == 2, "Observing tools cannot write ledger records")
    }

    private static func toolFollowUpsKeepTheOriginalCheck() throws {
        func record(_ action: [String: String], missing: Bool = false) -> InvestmentAgentToolCall {
            let call = LanguageModelCall(id: "same-provider-id", name: missing ? "inspect_entry_form" : "propose_changes", arguments: ["actions": [action]])
            var value = InvestmentAgentToolCall(call: call, book: InvestmentBook())
            value.finish(result: missing ? #"{"forms":[{"operation":"开空","missing":["成交价"]}]}"#
                         : #"{"status":"pending_user_confirmation","summary":"1 笔交易"}"#, elapsed: 0.1)
            return value
        }
        let action = ["action": "add_event", "account_id": "account-a", "asset_id": "TRXUSD•S•HTX", "date": "2026-11-11", "price": ""]
        let missing = record(action, missing: true)
        var filled = action; filled["price"] = "0.319505"
        let completed = record(filled)
        let records = [missing.id: missing, completed.id: completed]
        let timeline: [AssistantToolFollowUp.Entry] = [.init(id: missing.id), .init(id: completed.id)]
        precondition(AssistantToolFollowUp.resolved(timeline: timeline, records: records) == [missing.id: completed.id])
        precondition(missing.state == .needsClarification && missing.statusTitle == "参数待完善")
        precondition(missing.outputs.first?.value == "成交价", "Follow-up badges must not rewrite the original result")
        filled["account_id"] = "account-b"
        let unrelated = record(filled)
        precondition(AssistantToolFollowUp.resolved(timeline: [.init(id: missing.id), .init(id: unrelated.id)], records: [missing.id: missing, unrelated.id: unrelated]).isEmpty)
        precondition(AssistantToolFollowUp.resolved(timeline: [.init(id: missing.id), .init(id: UUID(), isUser: true), .init(id: completed.id)], records: records).isEmpty)
        let bytes = try PropertyListEncoder().encode([missing, completed])
        let loaded = try PropertyListDecoder().decode([InvestmentAgentToolCall].self, from: bytes)
        precondition(AssistantToolFollowUp.resolved(timeline: timeline, records: Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })) == [missing.id: completed.id])
    }

    @MainActor
    private static func toolCancellationAndMalformedArgumentsRemainVisible() async throws {
        let (base, _) = try contractDraft()
        let client = LanguageModelClient(configuration: .init(model: "fixture", token: "fixture"))
        let malformed = "{\"section\":"
        let response = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["role": "assistant", "content": "", "tool_calls": [
            ["id": "bad-args", "type": "function", "function": ["name": "read_ledger", "arguments": malformed]]
        ]]]]])
        let call = try client.decode(response).calls[0]
        precondition(call.arguments == nil && call.rawArguments == malformed)
        var updates: [InvestmentAgentToolCall] = []
        _ = try await InvestmentAgentToolCall.perform(call, book: base.book, update: { updates.append($0) }) {
            guard call.arguments != nil else { throw InvestmentError.invalid("工具参数无效。") }
            preconditionFailure("Malformed parameters cannot execute a tool")
        }
        precondition(updates.last?.arguments == malformed && updates.last?.state == .failed)
        precondition(InvestmentAgentToolCall.pretty(malformed) == malformed)

        let (ready, continuation) = AsyncStream<Void>.makeStream()
        let task = Task {
            try await InvestmentAgentToolCall.perform(call, book: base.book, update: { updates.append($0) }) {
                continuation.yield(()); continuation.finish()
                try await Task.sleep(for: .seconds(30))
                return "{}"
            }
        }
        for await _ in ready { break }
        task.cancel()
        do { _ = try await task.value; preconditionFailure("Cancellation cannot be reported as success") }
        catch is CancellationError { }
        precondition(updates.last?.state == .cancelled && updates.last?.result == nil)
        precondition(updates.last?.finishedAt != nil)
    }

    private static func savesToolRecordsWithoutChangingConversationFormat() throws {
        let (base, _) = try contractDraft()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = InvestmentAgentConversationFile(url: directory.appendingPathComponent("ledger.plist"))
        let other = InvestmentAgentConversationFile(url: directory.appendingPathComponent("other-ledger.plist"))
        let call = LanguageModelCall(id: "read-1", name: "read_ledger", arguments: ["section": "holdings", "account_id": base.book.accounts[0].id.uuidString])
        var first = InvestmentAgentToolCall(call: call, book: base.book)
        first.finish(result: "{\"rows\":[],\"total\":0}", elapsed: 0.25)
        let second = InvestmentAgentToolCall(call: call, book: base.book)
        let messages: [InvestmentAgentConversation.Message] = [.init(text: "查询账户", isUser: true),
            .init(text: "先核对账本。", isUser: false), first.message, second.message,
            .init(text: "再补充一个问题", isUser: true)]
        try file.save(.init(messages: messages, history: Data("[]".utf8), modelKey: nil, format: .openAI,
                            proposal: nil, canExport: false, commitStarted: false))
        let original = try Data(contentsOf: file.url)
        try file.saveToolCalls([first, second])
        let unchanged = try Data(contentsOf: file.url)
        precondition(original == unchanged, "Tool storage must not rewrite the conversation format")
        let loaded = try file.loadToolCalls()
        let isolated = try other.loadToolCalls()
        precondition(loaded == [first, second] && isolated.isEmpty)
        precondition(loaded[0].inputs.contains { $0.label == "账户" && $0.value == "加密套利" })
        precondition(loaded[0].outputs.first?.value == "0 条记录")
        precondition(loaded[0].restored().state == .succeeded)
        precondition(loaded[1].restored().state == .interrupted && loaded[1].restored().elapsed == nil)
        let conversation = try file.load()!
        precondition(conversation.messages.map(\.id) == messages.map(\.id))
        try file.saveComposerDraft(.init(text: "未发送的补充"))
        try file.remove()
        let clearedConversation = try file.load()
        let clearedTools = try file.loadToolCalls()
        let clearedDraft = try file.loadComposerDraft()
        precondition(clearedConversation == nil && clearedTools.isEmpty && clearedDraft.isEmpty)
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
            .init(text: "", isUser: false, html: AssistantHTML("<p><strong>明细</strong></p>"))
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
        precondition(AssistantHTML(response)?.fragment == expected)
        precondition(AssistantHTML("```html\r\n<p>1 < 2 &amp; &lt;img&gt;</p>\r\n```")?.fragment ==
                     "<p>1 &lt; 2 &amp; &lt;img&gt;</p>")
        precondition(AssistantHTML("<script>attack()</script><p> </p>") == nil)
        precondition(AssistantHTML(String(repeating: "a", count: 128_001)) == nil)
    }

    private static func savesConfirmedPreviewWithoutAnActiveDraft() throws {
        let (base, actions) = try contractDraft()
        let proposal = try InvestmentAgentProposal(base: base, actions: actions)
        let receipt = InvestmentAgentConversation.Message.recorded(proposal, at: InvestmentBook.day())
        precondition(receipt.html != nil && receipt.text.contains("已记账：1 笔交易"))
        for value in ["1153", "0.319505", "7217.4", "TRXUSD•S•HTX", "确认时间"] {
            precondition(receipt.text.contains(value) && receipt.html!.fragment.contains(value))
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = InvestmentAgentConversationFile(url: directory.appendingPathComponent("confirmed.plist"))
        try file.save(.init(messages: [receipt], history: Data("[]".utf8), modelKey: nil, format: .openAI,
            proposal: nil, canExport: false, commitStarted: false))
        let restored = try file.load()!
        precondition(restored.proposal == nil && !restored.commitStarted)
        precondition(restored.messages.first?.id == receipt.id && restored.messages.first?.text == receipt.text)
        precondition(restored.messages.first?.html?.fragment == receipt.html?.fragment)

        let named = try InvestmentAgentProposal(base: snapshot(InvestmentBook()), actions: [
            .init(kind: .addAccount, values: ["name": "<script>example</script>&账户", "currency": "CNY", "account_type": "securities"])
        ])
        let escaped = InvestmentAgentConversation.Message.recorded(named)
        precondition(escaped.html!.fragment.contains("&lt;script&gt;example&lt;/script&gt;&amp;账户"))
        precondition(!escaped.html!.fragment.contains("<script>"))
    }

    private static func savesComposerWithoutChangingTheConversation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = InvestmentAgentConversationFile(url: directory.appendingPathComponent("ledger-a.plist"))
        let other = InvestmentAgentConversationFile(url: directory.appendingPathComponent("ledger-b.plist"))
        let (base, actions) = try contractDraft()
        let proposal = try InvestmentAgentProposal(base: base, actions: actions)
        try file.save(.init(messages: [.init(text: "仍在核对的交易", isUser: true)], history: Data("[]".utf8),
            modelKey: nil, format: .openAI, proposal: proposal, canExport: false, commitStarted: false))
        let original = try Data(contentsOf: file.url)
        let draft = AssistantComposerDraft(text: "先保留，不发送\n确认到 11 号", attachments: [
            .init(photoIdentifier: "photo-1", data: Data([1, 2, 3])),
            .init(photoIdentifier: nil, data: Data([4, 5, 6]))
        ])
        try file.saveComposerDraft(draft)
        let reopened = try file.loadComposerDraft()
        let isolated = try other.loadComposerDraft()
        precondition(reopened == draft && isolated.isEmpty)
        let unchanged = try Data(contentsOf: file.url)
        let conversation = try file.load()!
        precondition(unchanged == original && conversation.proposal?.id == proposal.id)
        precondition(conversation.messages.first?.text == "仍在核对的交易")
        try file.saveComposerDraft(.init())
        let cleared = try file.loadComposerDraft()
        precondition(cleared.isEmpty && FileManager.default.fileExists(atPath: file.url.path))
        try file.saveComposerDraft(draft)
        try file.remove()
        let removed = try file.loadComposerDraft()
        precondition(removed.isEmpty && !FileManager.default.fileExists(atPath: file.url.path))
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
        precondition(preview.preview.summary == "1 笔交易" && preview.preview.items[0].sourceIDs.count == 2)
    }

    @MainActor
    private static func nativeEditorOnlyRevisesThePendingDraft() async throws {
        let (base, actions) = try contractDraft()
        let proposal = try InvestmentAgentProposal(base: base, actions: actions)
        let originalAsset = try actions[1].asset(in: proposal.book)
        var submitted: [InvestmentAgentAction]?
        let editor = InvestmentEditorDraft(proposal: proposal, index: 1, base: base.book) { submitted = $0 }
        precondition(proposal.entryEditorIndices == [1])
        let initial = try editor.editingBook()
        precondition(initial.asset(originalAsset.id) == nil && submitted == nil)
        try await editor.submit(["quantity": "10", "margin": "12", "fee": "", "account_id": base.book.accounts[0].id.uuidString], asset: originalAsset)
        let revised = try InvestmentAgentProposal(base: base, actions: submitted!)
        let event = revised.book.accounts[0].events.last!
        precondition(event.quantity == 10 && event.margin == 12 && event.fee == nil)
        precondition(revised.preview.summary == "1 笔交易" && revised.entryEditorIndices == [1])
        precondition(proposal.book.accounts[0].events.last?.quantity == 1153)
        precondition(base.book.accounts[0].events.count == 2 && base.book.asset(originalAsset.id) == nil)
    }

    private static func nativeEditorKeepsSharedRegistrationsAndOtherEntries() throws {
        let (base, initial) = try contractDraft()
        var second = initial[1]
        second.values["quantity"] = "2"
        second.values["margin"] = "1"
        let proposal = try InvestmentAgentProposal(base: base, actions: initial + [second])
        let shared = try second.asset(in: proposal.book)
        precondition(proposal.entryEditorIndices == [1, 2])
        let later = InvestmentEditorDraft(proposal: proposal, index: 2, base: base.book) { _ in }
        let context = try later.editingBook()
        precondition(context.asset(shared.id) != nil)
        precondition(context.accounts[0].events.last?.assetID == shared.id)
        precondition(context.accounts[0].events.last?.quantity == 1153)
        let revised = try later.replacing(values: ["quantity": "3"], selectedAsset: shared)
        precondition(revised.filter { $0.kind == .addAsset }.count == 1)
        let laterPreview = try InvestmentAgentProposal(base: base, actions: revised)
        precondition(laterPreview.book.accounts[0].events.suffix(2).map(\.quantity) == [1153, 3])

        var another = shared
        another.id = UUID()
        another.code = "TRXUSD_PERP"
        another.market = "BINANCE"
        let first = InvestmentEditorDraft(proposal: proposal, index: 1, base: base.book) { _ in }
        let split = try first.replacing(values: ["quantity": "1", "margin": "1"], selectedAsset: another)
        precondition(split.filter { $0.kind == .addAsset }.count == 2)
        let splitPreview = try InvestmentAgentProposal(base: base, actions: split)
        let events = Array(splitPreview.book.accounts[0].events.suffix(2))
        precondition(events.map(\.quantity) == [1, 2])
        precondition(splitPreview.book.asset(events[0].assetID)?.market == "BINANCE")
        precondition(splitPreview.book.asset(events[1].assetID)?.market == "HTX")
    }

    private static func nativeEditorUsesTheBalanceBeforeItsEntry() throws {
        let account = InvestmentAccount(name: "余额测试", currency: .usd, type: .securities)
        let target = InvestmentAccount(name: "划转目标", currency: .usd, type: .securities)
        var book = InvestmentBook(accounts: [account, target])
        let date = InvestmentEditorDraft.day.string(from: InvestmentBook.day())
        try book.post(.init(day: InvestmentBook.day(), kind: .deposit, amount: 100), accountID: account.id)
        let actions: [InvestmentAgentAction] = [
            .init(kind: .addEvent, values: ["account_id": account.id.uuidString, "event_type": "deposit", "amount": "50", "date": date]),
            .init(kind: .transfer, values: ["account_id": account.id.uuidString, "target_id": target.id.uuidString, "amount": "20", "date": date])
        ]
        let base = snapshot(book)
        let proposal = try InvestmentAgentProposal(base: base, actions: actions)
        let editor = InvestmentEditorDraft(proposal: proposal, index: 1, base: book) { _ in }
        let context = try editor.editingBook()
        let cash = try context.ledger(context.account(account.id)!).cash
        precondition(cash == 150)
        let revised = try editor.replacing(values: ["amount": "30", "remaining": "120", "received": ""])
        precondition(revised[1].values["remaining"] == nil)
        let preview = try InvestmentAgentProposal(base: base, actions: revised)
        let after = try preview.book.ledger(preview.book.account(account.id)!).cash
        precondition(after == 120 && book.accounts[0].events.count == 1)
    }

    private static func nativeEditorPreservesPlanIdentityAndCanClearItsAsset() throws {
        let account = InvestmentAccount(name: "定投测试", currency: .usd, type: .securities)
        var book = InvestmentBook(accounts: [account])
        let asset = InvestmentAsset(name: "Example", code: "TEST", market: "US", kind: .stock, currency: .usd)
        _ = try book.register(asset)
        let plan = InvestmentAgentAction(kind: .plan, values: ["account_id": account.id.uuidString,
            "asset_id": asset.id.uuidString, "plan_type": "buy", "amount": "10", "month_day": "8", "enabled": "true"])
        try plan.apply(to: &book)
        let id = book.plans[0].id
        let proposal = try InvestmentAgentProposal(base: snapshot(book), actions: [.init(kind: .plan, values: ["plan_id": id.uuidString, "amount": "20"])])
        let editor = InvestmentEditorDraft(proposal: proposal, index: 0, base: book) { _ in }
        let actions = try editor.replacing(values: ["plan_type": "deposit", "asset_id": "", "amount": "30"])
        let revised = try InvestmentAgentProposal(base: snapshot(book), actions: actions)
        precondition(revised.book.plans.count == 1 && revised.book.plans[0].id == id)
        precondition(revised.book.plans[0].assetID == nil && revised.book.plans[0].amount == 30)
        precondition(revised.book.plans[0].monthDay == 8 && book.plans[0].amount == 10)
    }

    private static func deletionPreviewsHaveNoEntryEditor() throws {
        let (base, actions) = try contractDraft()
        let committed = try InvestmentAgentProposal(base: base, actions: actions).book
        let entry = committed.accounts[0].events.last!
        let removal = InvestmentAgentAction(kind: .deleteEvent, values: ["account_id": committed.accounts[0].id.uuidString, "event_id": entry.id.uuidString])
        let proposal = try InvestmentAgentProposal(base: snapshot(committed), actions: [removal])
        precondition(!proposal.editable && proposal.entryEditorIndices.isEmpty)
        precondition(proposal.preview.items.count == 1 && proposal.preview.items[0].operation == .remove)
        let editor = InvestmentEditorDraft(proposal: proposal, index: 0, base: committed) { _ in }
        do {
            _ = try editor.replacing(values: ["quantity": "1"])
            preconditionFailure("Deletion must not open a data entry form")
        } catch is InvestmentError { }
        precondition(committed.accounts[0].events.last?.id == entry.id)
    }

    private static func nativeEditorKeepsOptionalValuationInTheSamePreview() throws {
        let account = InvestmentAccount(name: "理财", currency: .cny, type: .wealth)
        var book = InvestmentBook(accounts: [account])
        let date = InvestmentEditorDraft.day.string(from: InvestmentBook.day())
        try book.post(.init(day: InvestmentBook.day(), kind: .deposit, amount: 100), accountID: account.id)
        let actions: [InvestmentAgentAction] = [
            .init(kind: .addAsset, values: ["name": "理财产品", "symbol": "PRODUCT", "currency": "CNY", "asset_type": "wealth"]),
            .init(kind: .addEvent, values: ["account_id": account.id.uuidString, "asset_id": "PRODUCT", "date": date,
                "event_type": "buy", "quantity": "10", "price": "1"])
        ]
        let base = snapshot(book)
        let proposal = try InvestmentAgentProposal(base: base, actions: actions)
        let asset = try actions[1].asset(in: proposal.book)
        let editor = InvestmentEditorDraft(proposal: proposal, index: 1, base: book) { _ in }
        let revised = try InvestmentAgentProposal(base: base, actions: editor.replacing(values: [:], selectedAsset: asset, quote: 2))
        precondition(revised.entryEditorIndices == [1] && revised.preview.summary == "1 笔交易")
        precondition(revised.preview.items[0].groups.contains { $0.title == "估值信息" })
        let editing = InvestmentEditorDraft(proposal: revised, index: 1, base: book) { _ in }
        let selected = try revised.actions[1].asset(in: revised.book)
        let next = try editing.replacing(values: ["quantity": "12"], selectedAsset: selected, quote: 3)
        precondition(next.filter { $0.kind == .quote }.count == 1)
        let preview = try InvestmentAgentProposal(base: base, actions: next)
        let target = try next[1].asset(in: preview.book)
        precondition(preview.book.quote(target.id)?.price == 3)
        let cleared = try editing.replacing(values: [:], selectedAsset: selected)
        precondition(!cleared.contains { $0.kind == .quote })
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
        precondition(preview.preview.summary == "1 笔交易")
        precondition(preview.preview.items[0].groups.contains { $0.title.hasPrefix("同时记入") })
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

    private static func contractDraft() throws -> (InvestmentAgentSnapshot, [InvestmentAgentAction]) {
        let account = InvestmentAccount(name: "加密套利", currency: .usd, type: .crypto)
        var book = InvestmentBook(accounts: [account])
        let token = try book.register(.init(name: "TRON", code: "TRX", market: "", kind: .crypto, currency: .usd))
        let day = InvestmentBook.day()
        try book.post(.init(day: day, kind: .deposit, amount: 10000), accountID: account.id)
        try book.post(.init(day: day, kind: .buy, assetID: token, quantity: 10000, price: 1), accountID: account.id)
        return (snapshot(book), [
            .init(kind: .addAsset, values: ["name": "TRX/USD 永续", "symbol": "TRX-USD", "currency": "USD",
                "asset_type": "crypto_contract", "market": "HTX", "basis": "coin", "side": "short",
                "multiplier": "10", "collateral_id": token.uuidString]),
            .init(kind: .addEvent, values: ["account_id": account.id.uuidString, "asset_id": "TRX-USD",
                "date": InvestmentBook.snapshotDateFormatter().string(from: day), "event_type": "buy",
                "quantity_mode": "contracts", "quantity": "1153", "price": "0.319505", "margin": "7217.4", "fee": "0"])
        ])
    }

    private static func contractPreviewUsesOneEntryForm() throws {
        let (base, actions) = try contractDraft()
        let proposal = try InvestmentAgentProposal(base: base, actions: actions)
        precondition(proposal.changes.count == 5)
        let preview = proposal.preview
        precondition(preview.summary == "1 笔交易" && preview.items.count == 1)
        let item = preview.items[0]
        precondition(item.sourceIDs == Set(proposal.changes.map(\.id)))
        precondition(item.groups.map(\.title) == ["加密套利", "使用结算币余额"])
        let fields = item.groups.flatMap(\.fields)
        precondition(fields.first { $0.label == "资产类型" }?.after == "币本位合约")
        precondition(fields.first { $0.label == "报价交易所" }?.after == "HTX")
        precondition(fields.first { $0.label == "结算币种" }?.after == "TRX")
        precondition(fields.first { $0.label == "每张合约面值（USD）" }?.after == "10")
        precondition(fields.first { $0.label == "数量（张）" }?.after == "1153")
        precondition(fields.first { $0.label == "成交价（USD/TRX）" }?.after == "0.319505")
        precondition(fields.first { $0.label == "本次开仓保证金总额（TRX）" }?.after == "7217.4")
        precondition(!fields.contains { $0.id == "event_id" || $0.id == "instrument_id" || $0.id == "trade_action" })
        precondition(base.book.accounts[0].events.count == 2, "Preview must not write to the real ledger")
        var extra = actions
        extra.append(.init(kind: .addEvent, values: ["account_id": base.book.accounts[0].id.uuidString,
            "event_type": "deposit", "date": actions[1].values["date"]!, "amount": "25"]))
        let withDeposit = try InvestmentAgentProposal(base: base, actions: extra)
        precondition(withDeposit.preview.summary == "2 笔交易", "A real cash deposit must not be hidden as supporting data")
    }

    private static func existingContractRegistrationAcceptsNewTrades() throws {
        let (base, actions) = try contractDraft()
        var registered = base.book
        try actions[0].apply(to: &registered)
        let contract = registered.assets.values.first { $0.kind == .cryptoContract }!
        let records = InvestmentServerRecords()
        registered = try records.decode(.init(generation: 1, revision: 1, tables: records.encode(registered, revision: 1)))
        precondition(registered.asset(contract.id)?.collateralAssetID == contract.collateralAssetID)
        var trade = actions[1]
        trade.values["asset_id"] = contract.id.uuidString
        let choices = trade.form(in: registered).fields.first { $0.key == "event_type" }!.choices
        precondition(!choices.contains { $0.id == "opening" })
        precondition(choices.contains { $0.id == "buy" && $0.title == "开空" })
        let inspection = InvestmentAgentAction.inspect([trade], in: registered)[0]
        precondition((inspection["missing"] as? [String]) == [] && inspection["validation_error"] == nil)
        let proposal = try InvestmentAgentProposal(base: snapshot(registered), actions: [trade])
        precondition(proposal.preview.items.count == 1 && proposal.preview.summary == "1 笔交易")
        precondition(proposal.book.assets.count == registered.assets.count)
        precondition(proposal.book.accounts[0].events.last?.assetID == contract.id)

        // A registration retained by a watchlist can be reused after deleting the holding.
        var deleted = proposal.book
        deleted.watched = [contract.id]
        try deleted.deleteInvestment(accountID: base.book.accounts[0].id, assetID: contract.id)
        precondition(deleted.asset(contract.id) != nil)
        let reopened = try InvestmentAgentProposal(base: snapshot(deleted), actions: [trade])
        precondition(reopened.book.assets.count == registered.assets.count)
        precondition(reopened.book.accounts[0].events.last?.assetID == contract.id)
        var additional = trade
        additional.values["quantity"] = "1"
        additional.values["margin"] = "100"
        let increased = try InvestmentAgentProposal(base: snapshot(reopened.book), actions: [additional])
        precondition(increased.book.accounts[0].events.count == reopened.book.accounts[0].events.count + 1)

        var opening = trade
        opening.values["event_type"] = "opening"
        precondition(opening.form(in: registered).missing.contains("流水类型"))
        precondition((InvestmentAgentAction.inspect([opening], in: registered)[0]["validation_error"] as? String)?.contains("开空") == true)
        do { try opening.apply(to: &registered); preconditionFailure("Opening balances are not contract trades") }
        catch let error as InvestmentError {
            precondition(error.localizedDescription.contains("开空") && error.localizedDescription.contains("首次录入"))
            precondition(!error.localizedDescription.contains("结算币"))
        }
        registered.assets[contract.id]?.collateralAssetID = UUID()
        do { try trade.apply(to: &registered); preconditionFailure("A missing collateral reference must still be rejected") }
        catch let error as InvestmentError { precondition(error.localizedDescription.contains("结算币关联")) }
    }

    private static func contractDetailEditsAndDeletesKeepTheirTransaction() throws {
        let (base, actions) = try contractDraft()
        let committed = try InvestmentAgentProposal(base: base, actions: actions).book
        let event = committed.accounts[0].events.last!
        let edited = try InvestmentAgentProposal(base: snapshot(committed), actions: [
            .init(kind: .editEvent, values: ["account_id": committed.accounts[0].id.uuidString,
                "event_id": event.id.uuidString, "margin": "7000"])
        ])
        precondition(edited.changes.count == 1 && edited.changes[0].id.hasPrefix("investment_derivative_event_details:"))
        precondition(edited.preview.summary == "1 笔交易")
        let margin = edited.preview.items[0].groups.flatMap(\.fields).first { $0.id == "margin" }
        precondition(margin?.before == "7217.4" && margin?.after == "7000")
        precondition(edited.preview.items[0].groups.flatMap(\.fields).contains { $0.label == "数量（张）" && $0.after == "1153" })
        let deleted = try InvestmentAgentProposal(base: snapshot(committed), actions: [
            .init(kind: .deleteEvent, values: ["account_id": committed.accounts[0].id.uuidString, "event_id": event.id.uuidString])
        ])
        precondition(deleted.destructive && deleted.preview.summary == "1 笔交易")
        precondition(deleted.preview.items[0].groups.flatMap(\.fields).contains { $0.id == "margin_delta" && $0.before == "7217.4" && $0.after == nil })
    }

    private static func followUpReplacesUncommittedDraft() throws {
        let (base, actions) = try contractDraft()
        let original = try InvestmentAgentProposal(base: base, actions: actions)
        var corrected = original.actions
        corrected[1].values["quantity"] = "1100"
        let replacement = try InvestmentAgentProposal(base: base, actions: corrected)
        precondition(original.id != replacement.id && replacement.book.accounts[0].events.count == 3)
        precondition(original.book.accounts[0].events.last?.quantity == 1153)
        precondition(replacement.book.accounts[0].events.last?.quantity == 1100)
        let restored = replacement.restored(for: UUID())
        let context = try InvestmentAgentConversation.draftContext(restored, stale: true)
        let json = String(context[context.firstIndex(of: "{")!...])
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let parsed = try InvestmentAgentAction.parse(object)
        precondition(parsed.map(\.values) == corrected.map(\.values))
        precondition(context.contains("账本已变化") && context.contains("尚未写入"))
        precondition(!context.contains(original.id.uuidString) && !context.contains("1153"))
        let emptyContext = try InvestmentAgentConversation.draftContext(nil, stale: false)
        precondition(emptyContext.contains("当前没有待确认草稿"))
    }

    private static func incompleteContractRequiresClarification() throws {
        let (_, actions) = try contractDraft()
        for key in ["market", "basis", "side", "multiplier", "collateral_id"] {
            var fields = actions[0].values
            fields.removeValue(forKey: key)
            fields["action"] = "add_asset"
            do {
                _ = try InvestmentAgentAction.parse(["actions": [fields]])
                preconditionFailure("Missing contract information must be clarified: \(key)")
            } catch let error as InvestmentError {
                precondition(error.localizedDescription.contains("先向用户询问"))
            }
        }
    }

    private static func formInspectionCollectsMissingFieldsWithoutWriting() throws {
        let (base, actions) = try contractDraft()
        let partial = try InvestmentAgentAction.parse(["actions": [
            ["action": "add_asset", "asset_type": "crypto_contract", "basis": "coin", "name": "TRX/USD 永续"],
            ["action": "add_event", "event_type": "buy"]
        ]], requireComplete: false)
        let inspection = InvestmentAgentAction.inspect(partial, in: base.book)
        let instrumentMissing = inspection[0]["missing"] as! [String]
        precondition(Set(["报价币种", "代码", "报价交易所", "结算币种", "开仓方向", "每张合约面值（USD）"]).isSubset(of: Set(instrumentMissing)))
        let tradeMissing = inspection[1]["missing"] as! [String]
        precondition(Set(["所属账户", "已选标的", "成交日期"]).isSubset(of: Set(tradeMissing)))
        precondition(base.book.assets.count == 1 && base.book.accounts[0].events.count == 2)
        let ready = InvestmentAgentAction.inspect(actions, in: base.book)
        precondition(ready.allSatisfy { ($0["missing"] as? [String])?.isEmpty == true && $0["validation_error"] == nil })
        let form = InvestmentAgentAction(kind: .cashBalance, values: [:]).form(in: base.book)
        precondition(form.fields.first { $0.key == "account_id" }?.value == nil, "Even one account is not evidence of the user's intended account")
        precondition(form.fields.first { $0.key == "account_id" }?.choices.first?.title == "加密套利 · USD")
    }

    private static func coinEntryUsesPageQuantityConversions() throws {
        let (base, actions) = try contractDraft()
        for (mode, amount, expected) in [("coins", "35080", Decimal(1123)), ("notional", "11530", Decimal(1153)), ("contracts", "1153", Decimal(1153))] {
            var converted = actions
            converted[1].values["quantity_mode"] = mode
            converted[1].values["quantity"] = amount
            if mode == "coins" { converted[1].values["reference_price"] = "0.32" }
            let proposal = try InvestmentAgentProposal(base: base, actions: converted)
            precondition(proposal.book.accounts[0].events.last?.quantity == expected)
            let fields = proposal.preview.items[0].groups.flatMap(\.fields)
            precondition(fields.first { $0.id == "quantity" }?.after == amount)
            if mode != "contracts" { precondition(fields.first { $0.id == "contract_count" }?.after == NSDecimalNumber(decimal: expected).stringValue) }
        }
        let book = try InvestmentAgentProposal(base: base, actions: actions).book
        let event = book.accounts[0].events.last!
        let changedMode = InvestmentAgentAction(kind: .editEvent, values: ["account_id": book.accounts[0].id.uuidString,
            "event_id": event.id.uuidString, "quantity_mode": "coins", "reference_price": "0.32"])
        precondition(changedMode.form(in: book).missing.contains("仓位折算量（TRX）"))
        var copy = book
        do { try changedMode.apply(to: &copy); preconditionFailure("Changing units must not reinterpret stored contracts as coins") }
        catch is InvestmentError { }
        var cleared = changedMode
        cleared.values["quantity_mode"] = "contracts"
        cleared.values["quantity"] = ""
        precondition(cleared.form(in: book).missing.contains("数量（张）"))
    }

    private static func businessActionsGroupLinkedRecords() throws {
        let day = InvestmentBook.day()
        let date = InvestmentBook.snapshotDateFormatter().string(from: day)
        let account = InvestmentAccount(name: "证券", currency: .usd, type: .securities)
        var book = InvestmentBook(accounts: [account])
        let asset = try book.register(.init(name: "Example", code: "EX", market: "US", kind: .stock, currency: .usd))
        try book.post(.init(day: day, kind: .deposit, amount: 1000), accountID: account.id)
        try book.post(.init(day: day, kind: .buy, assetID: asset, quantity: 10, price: 10), accountID: account.id)
        let distribution = InvestmentAgentAction(kind: .distribution, values: ["account_id": account.id.uuidString,
            "asset_id": asset.uuidString, "date": date, "amount": "4", "quantity": "2"])
        let dividend = try InvestmentAgentProposal(base: snapshot(book), actions: [distribution])
        precondition(dividend.changes.count == 2 && dividend.preview.summary == "1 笔交易")
        precondition(dividend.preview.items[0].sourceIDs.count == 2)
        let buy = InvestmentAgentAction(kind: .addEvent, values: ["account_id": account.id.uuidString,
            "asset_id": asset.uuidString, "date": date, "event_type": "buy", "quantity": "1", "price": "10"])
        let identical = try InvestmentAgentProposal(base: snapshot(book), actions: [buy, buy])
        precondition(identical.preview.summary == "2 笔交易")
        precondition(identical.preview.items.allSatisfy { $0.sourceIDs.count == 1 })
        precondition(identical.preview.items[0].sourceIDs.isDisjoint(with: identical.preview.items[1].sourceIDs))
        let balance = try InvestmentAgentProposal(base: snapshot(book), actions: [
            .init(kind: .balanceAccount, values: ["name": "储蓄", "category": "cash", "amount": "500", "date": date])])
        precondition(balance.changes.count == 2 && balance.preview.summary == "1 项操作")
        precondition(balance.preview.items[0].sourceIDs == Set(balance.changes.map(\.id)))
    }

    private static func cashBalanceUsesAdjustment() throws {
        for type in [InvestmentAccountType.securities, .crypto] {
            let account = InvestmentAccount(name: "余额核对", currency: .usd, type: type)
            var book = InvestmentBook(accounts: [account])
            let day = InvestmentBook.day()
            try book.post(.init(day: day, kind: .deposit, amount: 100), accountID: account.id)
            let action = InvestmentAgentAction(kind: .cashBalance, values: ["account_id": account.id.uuidString,
                "date": InvestmentBook.snapshotDateFormatter().string(from: day), "amount": "80"])
            try action.apply(to: &book)
            precondition(book.accounts[0].events.last?.kind == .adjustment && book.accounts[0].events.last?.amount == -20)
            let ledger = try book.ledger(book.accounts[0])
            precondition(ledger.cash == 80)
        }
    }

    private static func termDepositsAndPlansFollowPageForms() throws {
        let account = InvestmentAccount(name: "存款", currency: .cny, type: .deposits)
        var book = InvestmentBook(accounts: [account])
        let day = InvestmentBook.day()
        let date = InvestmentBook.snapshotDateFormatter().string(from: day)
        let maturity = InvestmentBook.snapshotDateFormatter().string(from: InvestmentBook.addDays(365, to: day))
        try book.post(.init(day: day, kind: .deposit, amount: 1000), accountID: account.id)
        let setup = InvestmentAgentAction(kind: .addAsset, values: ["name": "一年定存", "currency": "CNY", "asset_type": "deposit",
            "annual_rate": "2", "maturity_date": maturity])
        precondition(setup.form(in: book).missing.isEmpty && !setup.form(in: book).fields.contains { $0.key == "symbol" })
        let entry = InvestmentAgentAction(kind: .addEvent, values: ["account_id": account.id.uuidString,
            "asset_id": "一年定存", "event_type": "buy", "date": date, "price": "1000", "settled_amount": "1000"])
        let proposal = try InvestmentAgentProposal(base: snapshot(book), actions: [setup, entry])
        precondition(proposal.preview.summary == "1 笔交易" && proposal.book.accounts[0].events.last?.quantity == 1)
        let stored = proposal.book.assets.values.first!
        precondition(!proposal.preview.items.flatMap(\.groups).flatMap(\.fields).contains { ($0.after ?? "").contains(stored.code) })
        let context = InvestmentAgentAction.inspect([setup, entry], in: book)
        precondition(context.allSatisfy { ($0["missing"] as? [String])?.isEmpty == true && $0["validation_error"] == nil })
        let unclear = InvestmentAgentAction(kind: .plan, values: ["account_id": account.id.uuidString, "amount": "100", "month_day": "5", "enabled": "true"])
        precondition(unclear.form(in: book).missing == ["任务类型"])
        let plan = InvestmentAgentAction(kind: .plan, values: ["plan_type": "deposit", "account_id": account.id.uuidString, "amount": "100", "month_day": "5", "enabled": "true"])
        try plan.apply(to: &book)
        let paused = InvestmentAgentAction(kind: .plan, values: ["plan_id": book.plans[0].id.uuidString, "enabled": "false"])
        precondition(paused.form(in: book).missing.isEmpty)
        try paused.apply(to: &book)
        precondition(!book.plans[0].enabled && book.plans[0].amount == 100)
        let deleted = try InvestmentAgentProposal(base: snapshot(book), actions: [.init(kind: .removePlan, values: ["plan_id": book.plans[0].id.uuidString])])
        precondition(deleted.preview.summary == "1 项操作" && deleted.destructive)
        precondition(!deleted.preview.items.flatMap(\.groups).flatMap(\.fields).contains { ($0.before ?? "").contains("未找到") })
    }

    private static func editingEntriesKeepsPageSignAndClearingRules() throws {
        let day = InvestmentBook.day()
        let source = InvestmentAccount(name: "美元", currency: .usd, type: .crypto)
        let target = InvestmentAccount(name: "人民币", currency: .cny, type: .securities)
        var book = InvestmentBook(accounts: [source, target])
        try book.post(.init(day: day, kind: .deposit, amount: 1000), accountID: source.id)
        try book.transfer(from: source.id, to: target.id, amount: 20, remaining: 980, received: 140, on: day)
        let outgoing = book.accounts[0].events.last!
        let edit = InvestmentAgentAction(kind: .editEvent, values: ["account_id": source.id.uuidString,
            "event_id": outgoing.id.uuidString, "amount": "25", "counterpart_amount": "170"])
        precondition(edit.form(in: book).fields.contains { $0.key == "counterpart_amount" && $0.label == "对方到账金额（CNY）" })
        let transfer = try InvestmentAgentProposal(base: snapshot(book), actions: [edit])
        precondition(transfer.book.accounts[0].events.last?.amount == -25 && transfer.book.accounts[1].events.last?.amount == 170)
        precondition(transfer.preview.summary == "1 笔交易" && transfer.preview.items[0].sourceIDs.count == 2)
        let token = try book.register(.init(name: "TRON", code: "TRX", market: "", kind: .crypto, currency: .usd))
        try book.post(.init(day: day, kind: .buy, assetID: token, quantity: 10, price: 1, fee: 2), accountID: source.id)
        let purchase = book.accounts[0].events.last!
        let clearFee = InvestmentAgentAction(kind: .editEvent, values: ["account_id": source.id.uuidString,
            "event_id": purchase.id.uuidString, "fee": ""])
        let cleared = try InvestmentAgentProposal(base: snapshot(book), actions: [clearFee])
        precondition(cleared.book.accounts[0].events.last?.fee == nil)
        precondition(cleared.preview.items[0].groups.flatMap(\.fields).contains { $0.id == "fee" && $0.before == "2" && $0.after == "未填写" })
        try book.adjustSpotBalance(assetID: token, accountID: source.id, balance: 8, on: day)
        let adjustment = book.accounts[0].events.last!
        let reduce = InvestmentAgentAction(kind: .editEvent, values: ["account_id": source.id.uuidString,
            "event_id": adjustment.id.uuidString, "quantity": "1"])
        try reduce.apply(to: &book)
        precondition(book.accounts[0].events.last?.quantity == -1)
        precondition(reduce.form(in: book).fields.contains { $0.key == "quantity" && $0.label == "减少数量" && $0.value == "1" })
    }

    private static func snapshotPreviewIncludesFetchedInputs() throws {
        let account = InvestmentAccount(name: "快照", currency: .cny, type: .securities)
        var book = InvestmentBook(accounts: [account])
        let day = InvestmentBook.addDays(-1, to: InvestmentBook.day())
        let asset = try book.register(.init(name: "Example", code: "600000.SH", market: "SH", kind: .stock, currency: .cny))
        try book.post(.init(day: day, kind: .deposit, amount: 1000), accountID: account.id)
        try book.post(.init(day: day, kind: .buy, assetID: asset, quantity: 10, price: 10), accountID: account.id)
        var prepared = book
        prepared.addQuotes([.init(day: day, price: 12, source: "手动录入")], assetID: asset)
        prepared.dailySnapshots = prepared.makeDailySnapshots(through: day, rebuild: true)
        let proposal = try InvestmentAgentProposal(base: snapshot(book), actions: [.init(kind: .rebuildSnapshots, values: [:])], prepared: prepared)
        precondition(proposal.changes.contains { $0.id.hasPrefix("investment_manual_prices:") })
        precondition(proposal.changes.contains { $0.id.hasPrefix("investment_daily_snapshots:") })
        precondition(proposal.preview.summary == "1 项操作")
        precondition(proposal.preview.items[0].groups.first?.fields.contains { $0.label == "数据完整性" } == true)
        precondition(book.dailySnapshots == nil && book.quotes[asset]?.isEmpty != false)
    }

    private static func relinkingContractPreservesTheTrade() throws {
        let (base, actions) = try contractDraft()
        var book = try InvestmentAgentProposal(base: base, actions: actions).book
        let event = book.accounts[0].events.last!
        let id = event.assetID!
        book.assets[id]!.code = "TRX-USD-SHORT"
        book.assets[id]!.instrumentID = UUID()
        let original = book.assets[id]!
        book.addQuotes([.init(day: event.day, price: 1, source: "旧行情")], assetID: id)
        let proposal = try InvestmentAgentProposal(base: snapshot(book), actions: [
            .init(kind: .editAsset, values: ["asset_id": id.uuidString, "symbol": "TRX-USD", "market": "HTX"])])
        let linked = proposal.book.asset(id)!
        precondition(linked.code == "TRX-USD" && linked.market == "HTX" && linked.instrumentID != original.instrumentID)
        precondition(linked.multiplier == original.multiplier && linked.basis == original.basis && linked.contractSide == original.contractSide)
        precondition(linked.collateralAssetID == original.collateralAssetID && proposal.book.accounts[0].events.last == event)
        precondition(proposal.book.quotes[id] == nil && book.quotes[id]?.count == 1)
        precondition(proposal.changes.contains { $0.operation == .remove })
        precondition(!proposal.destructive, "Replacing old quote data is not a user-requested deletion")
        precondition(proposal.preview.summary == "1 项操作")
        let receipt = InvestmentAgentConversation.Message.recorded(proposal)
        precondition(receipt.text.contains("原值：TRX-USD-SHORT") && receipt.text.contains("改为：TRX-USD"))
        precondition(proposal.preview.items[0].groups.flatMap(\.fields).contains { $0.id == "symbol" && $0.before == "TRX-USD-SHORT" && $0.after == "TRX-USD" })
    }

    private static func catalogIdentityIsReadOnlyAndContractAliasesResolve() throws {
        let (base, actions) = try contractDraft()
        let form = actions[0].form(in: base.book)
        for key in ["name", "symbol", "market", "multiplier"] {
            precondition(form.fields.first { $0.key == key }?.editable == false)
        }
        precondition(form.fields.first { $0.key == "name" }?.value == "TRX/USD 永续")
        precondition(form.fields.first { $0.key == "name" }?.displayValue == "TRX/USD 永续 · 空")
        precondition(form.fields.first { $0.key == "display_code" }?.displayValue == "TRXUSD•S•HTX")
        let proposal = try InvestmentAgentProposal(base: base, actions: actions)
        precondition(proposal.preview.items[0].groups.flatMap(\.fields).contains { $0.after?.contains("TRXUSD•S•HTX") == true })
        var book = proposal.book
        let htx = book.assets.values.first { $0.kind == .cryptoContract }!
        var binance = htx
        binance.id = UUID()
        binance.market = "BINANCE"
        binance.code = "TRXUSD_PERP"
        let binanceID = try book.register(binance)
        let date = InvestmentBook.snapshotDateFormatter().string(from: InvestmentBook.day())
        let quote = InvestmentAgentAction(kind: .quote, values: ["asset_id": "TRXUSD•S•BIN", "date": date, "price": "0.32"])
        try quote.apply(to: &book)
        precondition(book.quote(binanceID)?.price == Decimal(string: "0.32") && book.quote(htx.id) == nil)
        let rows = try InvestmentServerRecords().encode(book, revision: 1)
        precondition(rows["market_instruments"]?.contains { $0["symbol"] == "TRXUSD_PERP" && $0["exchange"] == "BINANCE" } == true)
        precondition(!rows.values.flatMap { $0 }.contains { $0["symbol"]?.contains("•") == true })
        let edit = InvestmentAgentAction(kind: .editAsset, values: ["asset_id": htx.id.uuidString]).form(in: book)
        precondition(edit.fields.first { $0.key == "name" }?.editable == false)
        precondition(edit.fields.first { $0.key == "name" }?.displayValue == "TRX/USD 永续 · 空")
        var aliasActions = actions
        aliasActions[1].values["asset_id"] = "TRXUSD•S•HTX"
        let aliasPreview = try InvestmentAgentProposal(base: base, actions: aliasActions)
        precondition(aliasPreview.preview.summary == "1 笔交易" && aliasPreview.preview.items.count == 1)
        precondition(aliasPreview.preview.items[0].sourceIDs == Set(aliasPreview.changes.map(\.id)))
        var another = binance
        another.id = UUID()
        another.contractSide = .long
        let longID = try book.register(another)
        let selectedShort = try quote.asset(in: book)
        precondition(selectedShort.id == binanceID)
        let longReference = InvestmentAgentAction(kind: .quote, values: ["asset_id": "TRXUSD•L•BIN"])
        let selectedLong = try longReference.asset(in: book)
        precondition(selectedLong.id == longID)
        var ambiguous = quote
        ambiguous.values["asset_id"] = "TRXUSD_PERP"
        do {
            try ambiguous.apply(to: &book)
            preconditionFailure("Ambiguous direction must require clarification")
        } catch is InvestmentError { }

        var longSetup = actions[0]
        longSetup.values["side"] = "long"
        var longEntry = aliasActions[1]
        longEntry.values["asset_id"] = "TRXUSD•L•HTX"
        longEntry.values["margin"] = "1000"
        let both = try InvestmentAgentProposal(base: base, actions: aliasActions + [longSetup, longEntry])
        precondition(both.preview.summary == "2 笔交易" && both.preview.items.count == 2)
        precondition(both.entryEditorIndices == [1, 3])
        precondition(both.assetSetupIndex(for: 1) == 0 && both.assetSetupIndex(for: 3) == 2)
        for (index, suffix) in [(0, "空"), (1, "多")] {
            precondition(both.preview.items[index].groups.flatMap(\.fields).contains { $0.after?.contains("TRX/USD 永续 · " + suffix) == true })
        }
    }

    private static func lifecycleActionsUseOneBusinessPreview() throws {
        let (base, actions) = try contractDraft()
        var committed = try InvestmentAgentProposal(base: base, actions: actions).book
        let owner = committed.accounts[0]
        let contract = committed.assets.values.first { $0.kind == .cryptoContract }!
        committed.addQuotes([.init(day: InvestmentBook.day(), price: 1, source: "测试行情")], assetID: contract.id)
        precondition(committed.deletionMessage(accountID: owner.id, assetID: contract.id).contains("TRX/USD 永续 · 空"))
        let deletion = try InvestmentAgentProposal(base: snapshot(committed), actions: [
            .init(kind: .removePosition, values: ["account_id": owner.id.uuidString, "asset_id": contract.id.uuidString])
        ])
        precondition(deletion.destructive && deletion.preview.items.count == 1)
        precondition(deletion.preview.items[0].title == "删除持仓")
        precondition(deletion.preview.items[0].groups.flatMap(\.fields).contains { $0.id == "records" && $0.before == "1 条" })
        precondition(deletion.book.accounts[0].events.count == 2 && deletion.book.asset(contract.id) == nil)
        precondition(deletion.preview.items[0].groups.flatMap(\.fields).contains { $0.id == "removed_assets" && $0.before == contract.displayName })
        precondition(!deletion.preview.items[0].groups.flatMap(\.fields).contains { $0.id == "retained_assets" })
        precondition(deletion.preview.items[0].sourceIDs.isSuperset(of: Set(deletion.changes.map(\.id))))
        let aliasDeletion = try InvestmentAgentProposal(base: snapshot(committed), actions: [
            .init(kind: .removePosition, values: ["account_id": owner.id.uuidString, "asset_id": contract.displayCode])
        ])
        precondition(aliasDeletion.preview.items[0].groups.flatMap(\.fields).contains { $0.id == "asset" && $0.before?.contains(contract.displayCode) == true })
        var shared = committed
        shared.watched = [contract.id]
        let retained = try InvestmentAgentProposal(base: snapshot(shared), actions: deletion.actions)
        precondition(retained.book.asset(contract.id) != nil && retained.book.quotes[contract.id] != nil)
        precondition(retained.preview.items[0].groups.flatMap(\.fields).contains { $0.id == "retained_assets" && $0.before?.contains(contract.displayName) == true })
        let rows = try InvestmentServerRecords().encode(deletion.book, revision: 1)
        precondition(rows["investment_derivative_event_details"]?.isEmpty == true)
        let deleteAccount = try InvestmentAgentProposal(base: snapshot(committed), actions: [
            .init(kind: .removeAccount, values: ["account_id": owner.id.uuidString])
        ])
        precondition(deleteAccount.book.accounts.isEmpty && deleteAccount.preview.items.count == 1)
        precondition(deleteAccount.book.assets.isEmpty)
        let fields = deleteAccount.preview.items[0].groups.flatMap(\.fields)
        precondition(fields.contains { $0.id == "records" && $0.before == "3 条" })
        precondition(fields.contains { $0.id == "consequence" && $0.before?.contains("无法撤销") == true })
        let invalid = InvestmentAgentAction(kind: .archiveAccount, values: ["account_id": owner.id.uuidString])
        precondition(InvestmentAgentAction.inspect([invalid], in: committed)[0]["validation_error"] != nil)
        let empty = InvestmentAccount(name: "空账户", currency: .usd, type: .crypto)
        let archived = try InvestmentAgentProposal(base: snapshot(.init(accounts: [empty])), actions: [
            .init(kind: .archiveAccount, values: ["account_id": empty.id.uuidString])
        ])
        precondition(archived.book.accounts[0].isArchived && archived.preview.items.count == 1)
        let restored = try InvestmentAgentProposal(base: snapshot(archived.book), actions: [
            .init(kind: .restoreAccount, values: ["account_id": empty.id.uuidString])
        ])
        precondition(!restored.book.accounts[0].isArchived && restored.preview.items.count == 1)
    }

    @MainActor
    private static func modelRetriesOnlyTheFailedRequest() async throws {
        let previousLogs = Set(HakoLogStore.shared.snapshot().entries.map(\.id))
        var sent: [Data] = []
        var waits: [Int] = []
        var notices: [Int] = []
        let client = LanguageModelClient(configuration: .init(baseURL: "https://privacy.example/private-path", model: "private-model", token: "private-token"),
            transport: { request in
                precondition(request.timeoutInterval == 600)
                sent.append(request.httpBody!)
                if sent.count < 3 { throw URLError(.networkConnectionLost) }
                return mockStream(request, events: openAIStream("private-reply"))
            }, retryDelay: { waits.append($0) })
        let input: [[String: Any]] = [["role": "user", "content": "private-question"],
            ["role": "assistant", "tool_calls": [["id": "call", "type": "function", "function": ["name": "read_ledger", "arguments": "{}"]]]],
            ["role": "tool", "tool_call_id": "call", "content": "private-tool-data"]]
        let reply = try await client.complete(system: "private-prompt", messages: input, onProgress: {
            if case .retrying(let attempt) = $0 { notices.append(attempt) }
        })
        precondition(reply.text == "private-reply" && sent.count == 3 && sent.allSatisfy { $0 == sent[0] })
        precondition(waits == [1, 2] && notices == [1, 2])
        let logs = HakoLogStore.shared.snapshot().entries.filter { !previousLogs.contains($0.id) && $0.message == "模型请求" && $0.detail.contains("privacy.example") }
        precondition(logs.count == 3 && logs.contains { $0.detail.contains("NSURLErrorDomain -1005") })
        for secret in ["private-path", "private-model", "private-token", "private-question", "private-tool-data", "private-reply", "private-prompt"] {
            precondition(!logs.contains { $0.detail.contains(secret) })
        }
    }

    private static func modelRetriesAreBoundedAndCancellable() async throws {
        let configuration = LanguageModelConfiguration(model: "test", token: "fixture")
        var attempts = 0
        let failing = LanguageModelClient(configuration: configuration, transport: { _ in
            attempts += 1
            throw URLError(.networkConnectionLost)
        }, retryDelay: { _ in })
        do {
            _ = try await failing.complete(system: "", messages: [])
            preconditionFailure("Repeated disconnects must terminate")
        } catch LanguageModelError.connection(let code, let retries) { precondition(code == .networkConnectionLost && retries == 2) }
        precondition(attempts == 3)
        for code in [URLError.Code.notConnectedToInternet, .cancelled, .secureConnectionFailed] {
            attempts = 0
            let permanent = LanguageModelClient(configuration: configuration, transport: { _ in
                attempts += 1
                throw URLError(code)
            }, retryDelay: { _ in preconditionFailure("Do not retry offline, cancellation, or TLS failures") })
            do { _ = try await permanent.complete(system: "", messages: []); preconditionFailure("Must report failure") }
            catch { precondition(attempts == 1) }
        }
        attempts = 0
        let cancelled = LanguageModelClient(configuration: configuration, transport: { _ in
            attempts += 1
            throw URLError(.networkConnectionLost)
        }, retryDelay: { _ in throw CancellationError() })
        do { _ = try await cancelled.complete(system: "", messages: []); preconditionFailure("Cancelled backoff must stop") }
        catch is CancellationError { precondition(attempts == 1) }
        for status in [401, 429, 503] {
            attempts = 0
            let rejected = LanguageModelClient(configuration: configuration, transport: { request in
                attempts += 1
                return mockStream(request, events: [], status: status)
            }, retryDelay: { _ in preconditionFailure("HTTP errors should retain their own handling") })
            do { _ = try await rejected.complete(system: "", messages: []); preconditionFailure("Must report HTTP error") }
            catch LanguageModelError.response(let received) { precondition(received == status && attempts == 1) }
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
            precondition(body["stream"] as? Bool == true && request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
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

    private static func wire(_ value: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }

    private static func openAIStream(_ text: String) -> [String] {
        [wire(["choices": [["index": 0, "delta": ["content": text]]]]),
         wire(["choices": [["index": 0, "delta": [:], "finish_reason": "stop"]]]), "[DONE]"]
    }

    private static func mockStream(_ request: URLRequest, events: [String], status: Int = 200) -> LanguageModelHTTPStream {
        .init(events: AsyncThrowingStream { continuation in
            continuation.yield(.sent)
            continuation.yield(.response(HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"])!))
            for event in events { continuation.yield(.data(Data(("data: " + event + "\n\n").utf8))) }
            continuation.finish()
        })
    }

    private static func streamingFramesAndToolsAreCompleteBeforeUse() throws {
        var decoder = LanguageModelSSEDecoder()
        var accumulator = LanguageModelStreamAccumulator(format: .openAI)
        let chunks: [[String: Any]] = [
            ["choices": [["index": 0, "delta": ["reasoning_content": "核对账本"]]]],
            ["choices": [["index": 0, "delta": ["content": "你好🤖"]]]],
            ["choices": [["index": 0, "delta": ["tool_calls": [["index": 0, "id": "call_1", "function": ["name": "read_", "arguments": "{\"scope\":"]]]]]]],
            ["choices": [["index": 0, "delta": ["tool_calls": [["index": 0, "function": ["name": "ledger", "arguments": "\"accounts\"}"]]]]]]],
            ["choices": [["index": 0, "delta": [:], "finish_reason": "tool_calls"]]]
        ]
        let frames = ": heartbeat\r\n\r\n" + chunks.map { "event: message\r\ndata: " + wire($0) + "\r\n\r\n" }.joined()
        for byte in frames.utf8 {
            for event in try decoder.append(Data([byte])) { try accumulator.append(event) }
        }
        precondition(accumulator.content == .init(text: "你好🤖", thinking: "核对账本"))
        do { _ = try accumulator.response(); preconditionFailure("An unterminated stream cannot execute a tool") }
        catch LanguageModelError.incompleteResponse(let retries) { precondition(retries == 0) }
        try accumulator.append("[DONE]")
        let client = LanguageModelClient(configuration: .init(model: "fixture", token: "fixture"))
        let reply = try client.decode(accumulator.response())
        precondition(reply.calls.count == 1 && reply.calls[0].name == "read_ledger")
        precondition(reply.calls[0].arguments?["scope"] as? String == "accounts")
        precondition(reply.message["reasoning_content"] as? String == "核对账本")

        var anthropic = LanguageModelStreamAccumulator(format: .anthropic)
        let events: [[String: Any]] = [
            ["type": "message_start", "message": ["content": []]],
            ["type": "content_block_start", "index": 0, "content_block": ["type": "thinking", "thinking": ""]],
            ["type": "content_block_delta", "index": 0, "delta": ["type": "thinking_delta", "thinking": "先确认账户"]],
            ["type": "content_block_delta", "index": 0, "delta": ["type": "signature_delta", "signature": "fixture-signature"]],
            ["type": "content_block_stop", "index": 0],
            ["type": "content_block_start", "index": 1, "content_block": ["type": "tool_use", "id": "tool_1", "name": "read_ledger", "input": [:]]],
            ["type": "content_block_delta", "index": 1, "delta": ["type": "input_json_delta", "partial_json": "{\"scope\":"]],
            ["type": "ping"],
            ["type": "content_block_delta", "index": 1, "delta": ["type": "input_json_delta", "partial_json": "\"accounts\"}"]],
            ["type": "content_block_stop", "index": 1],
            ["type": "message_delta", "delta": ["stop_reason": "tool_use"]],
            ["type": "message_stop"]
        ]
        for event in events { try anthropic.append(wire(event)) }
        let claude = LanguageModelClient(configuration: .init(format: .anthropic, model: "fixture", token: "fixture"))
        let result = try claude.decode(anthropic.response())
        precondition(result.calls.first?.arguments?["scope"] as? String == "accounts")
        precondition(anthropic.content.thinking == "先确认账户")
        let blocks = result.message["content"] as! [[String: Any]]
        precondition(blocks[0]["signature"] as? String == "fixture-signature")
        precondition(AssistantHTML.streamingText("<p>你好 &amp; &#128512;</p><stro") == "你好 & 😀")
        precondition(AssistantHTML.streamingText("<script>hidden</script><p>可见</p>") == "可见")
    }

    @MainActor
    private static func streamingProgressArrivesBeforeCompletion() async throws {
        let (events, continuation) = AsyncThrowingStream<LanguageModelHTTPEvent, Error>.makeStream()
        var progress: [LanguageModelRequestProgress] = []
        var updates: [LanguageModelStreamContent] = []
        var released = false
        let client = LanguageModelClient(configuration: .init(model: "fixture", token: "fixture"), transport: { request in
            continuation.yield(.sent)
            continuation.yield(.response(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"])!))
            continuation.yield(.data(Data(("data: " + openAIStream("第一段")[0] + "\n\n").utf8)))
            return .init(events: events)
        })
        let reply = try await client.complete(system: "", messages: [], onProgress: { progress.append($0) }, onContent: { content in
            updates.append(content)
            if content.text == "第一段" && !released {
                released = true
                for event in openAIStream("第二段") { continuation.yield(.data(Data(("data: " + event + "\n\n").utf8))) }
                continuation.finish()
            }
        })
        precondition(released && reply.text == "第一段第二段")
        precondition(progress == [.sending, .waitingForResponse, .receiving, .receivedResponse])
        precondition(updates.first == .init() && updates.last?.text == reply.text)
    }

    private static func streamingPresentationSurvivesToolsAndRetries() {
        var stream = InvestmentAgentStream()
        let replyID = stream.id
        stream.beginResponse(continuing: false)
        precondition(stream.progressTitle(.waitingForResponse) == LanguageModelRequestProgress.waitingForResponse.title)
        stream.receive(.init(text: "先查合约", thinking: "识别截图"))

        // A completed tool round remains visible while the next model request is waiting.
        stream.finishResponse("先查合约")
        stream.beginResponse(continuing: true)
        stream.receive(.init())
        precondition(stream.id == replyID && stream.hasContent)
        precondition(stream.thinking == "识别截图" && stream.text == "先查合约")
        precondition(stream.progressTitle(.waitingForResponse).contains("查询结果已发送"))
        stream.receive(.init(thinking: "核对交易所"))
        precondition(stream.thinking == "识别截图\n\n核对交易所")
        precondition(stream.text == "先查合约")

        // An incomplete attempt is kept and labelled, but its answer body cannot leak into the retry.
        _ = stream.progressTitle(.retrying(1))
        stream.receive(.init())
        precondition(stream.id == replyID && stream.hasContent)
        precondition(stream.thinking.contains("中断的响应：\n核对交易所"))
        precondition(stream.progressTitle(.waitingForResponse).contains("重试请求已发送"))
        stream.receive(.init(text: "请确认账户", thinking: "重新核对账户"))
        precondition(stream.text == "先查合约\n\n请确认账户" && stream.thinking.hasSuffix("重新核对账户"))
        precondition(stream.thinking.components(separatedBy: "识别截图").count == 2)

        // Explicit retry also keeps the same visible reply; a genuinely new turn starts empty.
        stream.interruptResponse()
        stream.beginResponse(continuing: true)
        stream.receive(.init())
        precondition(stream.id == replyID && stream.thinking.contains("重新核对账户"))
        let next = InvestmentAgentStream()
        precondition(next.id != replyID && !next.hasContent)
    }

    private static func savesToolRepliesAndInterruptedReplies() throws {
        var stream = InvestmentAgentStream()
        stream.beginResponse(continuing: false)
        stream.receive(.init(text: "<p>先核对已有登记。</p>"))
        let id = stream.id
        stream.finishResponse("<p>先核对已有登记。</p>")
        stream.beginResponse(continuing: true)
        stream.receive(.init(text: "<p>这条登记可以复用。</p>"))
        let interrupted = stream.message(incomplete: true)!
        precondition(interrupted.id == id && interrupted.text.contains("先核对已有登记") && interrupted.text.contains("尚未完成"))
        stream.interruptResponse()
        stream.receive(.init(text: "<p>继续录入这笔流水。</p>"))
        stream.finishResponse("<p>继续录入这笔流水。</p>")
        let finished = stream.message(incomplete: false, outcome: "请核对草稿。")!
        precondition(finished.id == id && !finished.text.contains("尚未完成"))
        precondition(finished.text.contains("先核对已有登记") && finished.text.contains("继续录入这笔流水"))
        precondition(!finished.text.contains("这条登记可以复用"), "An interrupted attempt must not leak into its replacement")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = InvestmentAgentConversationFile(url: directory.appendingPathComponent("replies.plist"))
        var later = InvestmentAgentStream()
        precondition(later.id != id && !later.hasContent)
        try file.save(.init(messages: [interrupted], history: Data("[]".utf8), modelKey: nil, format: .openAI,
            proposal: nil, canExport: false, commitStarted: false))
        let restoredPartial = try file.load()!
        precondition(restoredPartial.messages[0].text.contains("尚未完成"))
        later.receive(.init(text: "<p>正在处理下一条问题。</p>"))
        try file.save(.init(messages: [finished, .init(text: "继续提问", isUser: true), later.message(incomplete: true)!], history: Data("[]".utf8),
            modelKey: "another-model", format: .anthropic, proposal: nil, canExport: false, commitStarted: false))
        let restored = try file.load()!
        precondition(restored.messages.count == 3 && restored.messages[0].html?.fragment == finished.html?.fragment)
        precondition(restored.messages[2].text.contains("尚未完成"))
    }

    @MainActor
    private static func truncatedStreamsRetryWithoutMixingContent() async throws {
        var attempts = 0
        var updates: [LanguageModelStreamContent] = []
        var presentation = InvestmentAgentStream()
        presentation.beginResponse(continuing: false)
        let client = LanguageModelClient(configuration: .init(model: "fixture", token: "fixture"), transport: { request in
            attempts += 1
            return mockStream(request, events: attempts == 1 ? Array(openAIStream("未完成").prefix(1)) : openAIStream("完整回复"))
        }, retryDelay: { _ in })
        let reply = try await client.complete(system: "", messages: [], onProgress: { _ = presentation.progressTitle($0) }, onContent: { content in
            updates.append(content)
            presentation.receive(content)
            if content == .init(), attempts == 1 {
                precondition(presentation.hasContent && presentation.text == "未完成", "Retry must not remove the visible response")
            }
        })
        precondition(attempts == 2 && reply.text == "完整回复")
        precondition(updates.filter { $0 == .init() }.count == 2 && updates.last?.text == "完整回复")
        precondition(!updates.contains { $0.text == "未完成完整回复" })
        precondition(presentation.text == "完整回复")

        attempts = 0
        let truncated = LanguageModelClient(configuration: .init(model: "fixture", token: "fixture"), transport: { request in
            attempts += 1
            return mockStream(request, events: Array(openAIStream("只返回一部分").prefix(1)))
        }, retryDelay: { _ in })
        do { _ = try await truncated.complete(system: "", messages: []); preconditionFailure("An incomplete response must not be accepted") }
        catch LanguageModelError.incompleteResponse(let retries) { precondition(retries == 2 && attempts == 3) }
        let timeout = LanguageModelError.connection(.timedOut, retries: 2).localizedDescription
        let disconnected = LanguageModelError.connection(.networkConnectionLost, retries: 2).localizedDescription
        let incomplete = LanguageModelError.incompleteResponse(retries: 2).localizedDescription
        precondition(timeout.contains("超时") && disconnected.contains("中途断开") && incomplete.contains("内容未收全"))
    }

    private final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func set() { lock.withLock { cancelled = true } }
        var value: Bool { lock.withLock { cancelled } }
    }

    @MainActor
    private static func cancellingAStreamClosesItsTransport() async throws {
        let (ready, started) = AsyncStream<Void>.makeStream()
        let (events, continuation) = AsyncThrowingStream<LanguageModelHTTPEvent, Error>.makeStream()
        let cancelled = CancellationFlag()
        let client = LanguageModelClient(configuration: .init(model: "fixture", token: "fixture"), transport: { request in
            continuation.yield(.sent)
            continuation.yield(.response(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"])!))
            return .init(events: events, cancel: { cancelled.set(); continuation.finish() })
        }, retryDelay: { _ in preconditionFailure("Cancelled streams must not retry") })
        let request = Task {
            try await client.complete(system: "", messages: [], onProgress: { phase in
                if phase == .waitingForResponse { started.yield(()); started.finish() }
            })
        }
        for await _ in ready { break }
        request.cancel()
        do { _ = try await request.value; preconditionFailure("Cancellation must discard incomplete output") }
        catch is CancellationError { }
        precondition(cancelled.value)
    }
}
