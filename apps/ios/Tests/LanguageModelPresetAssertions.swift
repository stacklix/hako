import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension InvestmentAgentTests {
    static func modelPresetsConfigureOnlySupportedParameters() throws {
        precondition(Set(LanguageModelPreset.all.map(\.provider)) == Set(LanguageModelProvider.allCases))
        precondition(Set(LanguageModelPreset.all.map(\.id)).count == LanguageModelPreset.all.count)
        for preset in LanguageModelPreset.all {
            for speed in preset.speeds {
                for effort in preset.efforts.map(Optional.some) + [nil] {
                    var configuration = LanguageModelConfiguration()
                    preset.configure(&configuration)
                    configuration.token = "test-key"
                    configuration.speed = speed
                    configuration.reasoningEffort = effort
                    let client = LanguageModelClient(configuration: configuration)
                    let request = try client.request(system: "Test", messages: [client.userMessage("Hello")], tools: [])
                    let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                    switch preset.provider {
                    case .openAI:
                        precondition(request.url?.path == "/v1/responses" && body["messages"] == nil)
                        precondition(body["service_tier"] as? String == (speed == .standard ? "default" : speed.rawValue))
                        precondition((body["reasoning"] as? [String: String])?["effort"] == effort)
                    case .claude:
                        precondition(body["reasoning_effort"] == nil && (body["output_config"] as? [String: String])?["effort"] == effort)
                        precondition((body["thinking"] as? [String: String])?["type"] == "adaptive")
                        precondition((body["speed"] as? String == "fast") == (speed == .fast))
                    case .kimi:
                        precondition(body["model"] as? String == (speed == .fast ? preset.fastModel : preset.model))
                        precondition(body["service_tier"] == nil && body["reasoning_effort"] as? String == effort)
                    case .miniMax where preset.model == "MiniMax-M3":
                        precondition(body["reasoning_effort"] == nil)
                        precondition((body["thinking"] as? [String: String])?["type"] == effort.map { $0 == "none" ? "disabled" : "adaptive" })
                    default: precondition(body["reasoning_effort"] as? String == effort && body["service_tier"] == nil)
                    }
                    let restored = try JSONDecoder().decode(LanguageModelConfiguration.self, from: JSONEncoder().encode(configuration))
                    precondition(restored == configuration)
                }
            }
        }
        var configured = LanguageModelConfiguration()
        let sol = LanguageModelPreset.all.first { $0.model == "gpt-6.1-sol" }!
        sol.configure(&configured); configured.token = "private-token"
        configured.reasoningEffort = "none"
        do { _ = try configured.endpoint(); preconditionFailure("Sol must reject unsupported none reasoning") }
        catch LanguageModelError.invalid { }
        let kimi = LanguageModelPreset.all.first { $0.provider == .kimi }!
        kimi.configure(&configured)
        precondition(configured.token.isEmpty, "Changing vendors must clear the previous vendor's credential")
        configured.baseURL = "https://api.moonshot.cn/v1"; configured.token = "regional-key"
        kimi.configure(&configured)
        precondition(configured.token == "regional-key" && configured.baseURL == "https://api.moonshot.cn/v1")
        let pro = LanguageModelPreset.all.first { $0.model == "deepseek-v4-pro" }!
        pro.configure(&configured); configured.token = "test"
        let client = LanguageModelClient(configuration: configured)
        do { _ = try client.request(system: "", messages: [client.userMessage("", images: [Data([1])])], tools: []); preconditionFailure("Text-only model accepted an image") }
        catch LanguageModelError.invalid { }
    }

    static func responsesPreserveToolsAndReasoningAcrossTurns() async throws {
        let wire: (Any) throws -> String = { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        let reasoning: [String: Any] = ["type": "reasoning", "id": "rs_1", "encrypted_content": "encrypted-fixture", "summary": []]
        let call: [String: Any] = ["type": "function_call", "id": "fc_1", "call_id": "call-1", "name": "probe", "arguments": #"{"value":"ping"}"#]
        let text: [String: Any] = ["type": "message", "id": "msg_1", "role": "assistant", "content": [["type": "output_text", "text": "完成"]]]
        var accumulator = LanguageModelStreamAccumulator(format: .responses)
        try accumulator.append(wire(["type": "response.output_text.delta", "delta": "完"]))
        precondition(accumulator.content.text == "完" && !accumulator.finished)
        do { _ = try accumulator.response(); preconditionFailure("Partial tool calls must not be executable") }
        catch LanguageModelError.incompleteResponse { }
        try accumulator.append(wire(["type": "response.completed", "response": ["status": "completed", "output": [reasoning, call, text]]]))
        var configuration = LanguageModelConfiguration()
        LanguageModelPreset.all[0].configure(&configuration); configuration.token = "fixture"
        let client = LanguageModelClient(configuration: configuration)
        let reply = try client.decode(accumulator.response())
        precondition(reply.text == "完成" && reply.calls.first?.id == "call-1" && reply.calls.first?.arguments?["value"] as? String == "ping")
        let tool = LanguageModelTool(name: "probe", description: "Test", properties: [:], required: [])
        let history = [client.userMessage("Question")] + reply.messages + client.toolMessages([(reply.calls[0], "ok")])
        let request = try client.request(system: "Test", messages: history, tools: [tool])
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let input = body["input"] as! [[String: Any]]
        precondition(input[1]["encrypted_content"] as? String == "encrypted-fixture")
        precondition(input[2]["call_id"] as? String == "call-1" && input.last?["call_id"] as? String == "call-1")
        precondition(body["store"] as? Bool == false && (body["tools"] as? [[String: Any]])?.first?["name"] as? String == "probe")
        precondition((body["tools"] as? [[String: Any]])?.first?["strict"] as? Bool == false)

        let delta = try wire(["type": "response.output_text.delta", "delta": "完"])
        let completed = try wire(["type": "response.completed", "response": ["status": "completed", "output": [reasoning, call, text]]])
        let streamed = LanguageModelClient(configuration: configuration, transport: { request in
            let (events, continuation) = AsyncThrowingStream<LanguageModelHTTPEvent, Error>.makeStream()
            continuation.yield(.sent)
            continuation.yield(.response(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                                        headerFields: ["Content-Type": "text/event-stream"])!))
            for frame in [delta, completed] { continuation.yield(.data(Data(("data: " + frame + "\n\n").utf8))) }
            continuation.finish()
            return .init(events: events)
        })
        let streamedReply = try await streamed.complete(system: "Test", messages: [streamed.userMessage("Question")], tools: [tool])
        precondition(streamedReply.calls.first?.id == "call-1" && streamedReply.text == "完成" && streamedReply.messages.count == 3)

        var gemini = LanguageModelStreamAccumulator(format: .openAI)
        try gemini.append(wire(["choices": [["index": 0, "delta": ["tool_calls": [["index": 0, "id": "g1", "function": ["name": "probe", "arguments": "{}"], "extra_content": ["google": ["thought_signature": "signature"]]]]]]]]))
        try gemini.append(wire(["choices": [["index": 0, "delta": [:], "finish_reason": "tool_calls"]]]))
        try gemini.append("[DONE]")
        let chat = LanguageModelClient(configuration: .init(model: "fixture", token: "fixture"))
        let result = try chat.decode(gemini.response())
        let metadata = (result.message["tool_calls"] as? [[String: Any]])?.first?["extra_content"] as? [String: [String: String]]
        precondition(metadata?["google"]?["thought_signature"] == "signature", "Gemini tool continuation lost its thought signature")
    }

    static func modelAPIErrorsExplainAndRedactCredentials() async throws {
        let client = LanguageModelClient(configuration: .init(model: "fixture", token: "sk-secret-token"), transport: { request in
            let (events, continuation) = AsyncThrowingStream<LanguageModelHTTPEvent, Error>.makeStream()
            continuation.yield(.response(HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!))
            continuation.yield(.data(Data(#"{"error":{"message":"Unsupported parameter for sk-secret-token; use a supported effort."}}"#.utf8)))
            continuation.finish()
            return .init(events: events)
        })
        do { _ = try await client.complete(system: "", messages: []); preconditionFailure("API error was ignored") }
        catch LanguageModelError.rejected(let code, let detail) {
            precondition(code == 400 && detail.contains("supported effort") && !detail.contains("sk-secret-token"))
        }
    }
}
