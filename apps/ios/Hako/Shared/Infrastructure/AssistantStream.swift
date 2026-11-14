import Foundation

protocol AssistantReplyMessage {
    init(replyID: UUID, text: String, html: AssistantHTML?)
}

/// Accumulates one visible reply and keeps partial content stable during network retries.
struct AssistantStream<Message: AssistantReplyMessage>: Equatable {
    let id = UUID()
    private var response = LanguageModelStreamContent()
    private var completedReplies: [String] = []
    private var previousThinking: [String] = []
    private var continuing = false
    private var retryCount = 0

    private var replyParts: [String] { (completedReplies + [response.text]).filter { !$0.isEmpty } }
    var text: String { replyParts.joined(separator: "\n\n") }
    var displayText: String { replyParts.map(AssistantHTML.streamingText).filter { !$0.isEmpty }.joined(separator: "\n\n") }
    var thinking: String {
        (previousThinking + [response.thinking]).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
    var hasContent: Bool { !text.isEmpty || !thinking.isEmpty }

    mutating func beginResponse(continuing: Bool) {
        preserveThinking(interrupted: false)
        self.continuing = continuing
        retryCount = 0
    }

    mutating func receive(_ content: LanguageModelStreamContent) {
        // The transport resets its accumulator before each attempt. Keep the visible
        // attempt until replacement content arrives. Completed tool rounds stay in the reply.
        guard content != .init() else { return }
        response = content
    }

    mutating func finishResponse(_ text: String) {
        if !text.isEmpty { completedReplies.append(text) }
        response.text = ""
    }

    func message(incomplete: Bool, outcome: String? = nil) -> Message? {
        guard hasContent || outcome != nil else { return nil }
        let body = displayText
        let status = incomplete ? "本轮回复尚未完成。" : outcome
        let plain = [body, status].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        let html = replyParts.compactMap { AssistantHTML($0)?.fragment }.joined(separator: "\n")
            + (status.map { "<p>" + $0 + "</p>" } ?? "")
        return .init(replyID: id, text: plain, html: AssistantHTML(html))
    }

    mutating func interruptResponse() { preserveThinking(interrupted: true) }

    mutating func progressTitle(_ progress: LanguageModelRequestProgress) -> String {
        if case .retrying(let attempt) = progress {
            retryCount = attempt
            interruptResponse()
        }
        switch progress {
        case .sending where retryCount > 0: return "正在重试发送（\(retryCount)/2）…"
        case .waitingForResponse where retryCount > 0: return "重试请求已发送，等待模型响应（\(retryCount)/2）…"
        case .sending where continuing: return "正在发送查询结果，请模型继续处理…"
        case .waitingForResponse where continuing: return "查询结果已发送，等待模型继续回复…"
        default: return progress.title
        }
    }

    private mutating func preserveThinking(interrupted: Bool) {
        guard !response.thinking.isEmpty else { return }
        previousThinking.append((interrupted ? "以下思考来自中断的响应：\n" : "") + response.thinking)
        response.thinking = ""
    }
}
