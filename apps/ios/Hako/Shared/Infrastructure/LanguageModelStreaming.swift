import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum LanguageModelHTTPEvent: Sendable {
    case sent
    case response(URLResponse)
    case data(Data)
}

struct LanguageModelHTTPStream {
    let events: AsyncThrowingStream<LanguageModelHTTPEvent, Error>
    var cancel: @Sendable () -> Void = {}
}

enum LanguageModelTimeout {
    static let idle: TimeInterval = 600
}

final class LanguageModelStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let continuation: AsyncThrowingStream<LanguageModelHTTPEvent, Error>.Continuation
    // URLSession delivers callbacks serially on its delegate queue.
    private var sent = false
    private var received = 0

    private init(_ continuation: AsyncThrowingStream<LanguageModelHTTPEvent, Error>.Continuation) {
        self.continuation = continuation
    }

    static func open(_ request: URLRequest) -> LanguageModelHTTPStream {
        let (events, continuation) = AsyncThrowingStream<LanguageModelHTTPEvent, Error>.makeStream()
        let delegate = LanguageModelStreamDelegate(continuation)
        // Do not impose a short total deadline on a stream that is still delivering data.
        let session = HTTPTransport.makeSession(requestTimeout: LanguageModelTimeout.idle, delegate: delegate)
        continuation.onTermination = { _ in session.invalidateAndCancel() }
        session.dataTask(with: request).resume()
        return .init(events: events, cancel: { session.invalidateAndCancel() })
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard !sent, totalBytesExpectedToSend > 0, totalBytesSent >= totalBytesExpectedToSend else { return }
        sent = true
        continuation.yield(.sent)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        continuation.yield(.response(response))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        received += data.count
        guard received <= 8 * 1024 * 1024 else {
            continuation.finish(throwing: LanguageModelError.invalid("模型回复过长，请缩小请求范围。"))
            dataTask.cancel()
            return
        }
        continuation.yield(.data(data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { continuation.finish(throwing: error) }
        else { continuation.finish() }
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Keep byte fragments until a whole SSE line is available, including split UTF-8 characters.
struct LanguageModelSSEDecoder {
    private var buffer = Data()
    private var lines: [String] = []
    private var eventSize = 0

    mutating func append(_ data: Data) throws -> [String] {
        buffer.append(data)
        guard buffer.count + eventSize <= 1024 * 1024 else { throw LanguageModelError.unreadable }
        var events: [String] = []
        while let end = buffer.firstIndex(of: 10) {
            let bytes = buffer[..<end]
            guard var line = String(data: bytes, encoding: .utf8) else { throw LanguageModelError.unreadable }
            buffer.removeSubrange(...end)
            if line.hasSuffix("\r") { line.removeLast() }
            if line.isEmpty {
                if !lines.isEmpty { events.append(lines.joined(separator: "\n")) }
                lines.removeAll(keepingCapacity: true)
                eventSize = 0
            } else if line.hasPrefix("data:") {
                var value = String(line.dropFirst(5))
                if value.hasPrefix(" ") { value.removeFirst() }
                lines.append(value)
                eventSize += value.utf8.count
            }
        }
        return events
    }
}

struct LanguageModelStreamContent: Equatable, Sendable {
    var text = ""
    var thinking = ""
}

/// Tool arguments are accumulated here, never exposed as executable calls before the terminal event.
struct LanguageModelStreamAccumulator {
    let format: LanguageModelFormat
    private(set) var content = LanguageModelStreamContent()
    private(set) var finished = false
    private var stopReason: String?
    private var started = false
    private var calls: [Int: (id: String, name: String, arguments: String)] = [:]
    private var blocks: [Int: [String: Any]] = [:]
    private var inputs: [Int: String] = [:]
    private var openBlocks: Set<Int> = []

    mutating func append(_ event: String) throws {
        guard !finished else { return }
        if format == .openAI, event == "[DONE]" {
            guard stopReason != nil else { throw LanguageModelError.unreadable }
            finished = true
            return
        }
        guard let object = try JSONSerialization.jsonObject(with: Data(event.utf8)) as? [String: Any] else {
            throw LanguageModelError.unreadable
        }
        if object["error"] != nil {
            throw LanguageModelError.invalid("模型服务在返回过程中报告错误，请重试。")
        }
        switch format {
        case .openAI: try appendOpenAI(object)
        case .anthropic: try appendAnthropic(object)
        }
    }

    private mutating func appendOpenAI(_ object: [String: Any]) throws {
        guard let choices = object["choices"] as? [[String: Any]] else { throw LanguageModelError.unreadable }
        guard let choice = choices.first(where: { ($0["index"] as? Int) == 0 }) else { return }
        if let reason = choice["finish_reason"] as? String {
            guard ["stop", "tool_calls", "content_filter"].contains(reason) else {
                throw LanguageModelError.invalid("模型回复未完整生成，请缩小请求范围后重试。")
            }
            stopReason = reason
        }
        guard let delta = choice["delta"] as? [String: Any] else { return }
        content.text += (delta["content"] as? String) ?? (delta["refusal"] as? String) ?? ""
        content.thinking += delta["reasoning_content"] as? String ?? ""
        for part in delta["tool_calls"] as? [[String: Any]] ?? [] {
            guard let index = part["index"] as? Int, index >= 0, index < 64 else { throw LanguageModelError.unreadable }
            var call = calls[index] ?? ("", "", "")
            call.id += part["id"] as? String ?? ""
            if let function = part["function"] as? [String: Any] {
                call.name += function["name"] as? String ?? ""
                call.arguments += function["arguments"] as? String ?? ""
            }
            calls[index] = call
        }
    }

    private mutating func appendAnthropic(_ object: [String: Any]) throws {
        switch object["type"] as? String {
        case "message_start": started = true
        case "content_block_start":
            guard let index = object["index"] as? Int, index >= 0, index < 128, blocks[index] == nil,
                  let block = object["content_block"] as? [String: Any] else { throw LanguageModelError.unreadable }
            blocks[index] = block
            openBlocks.insert(index)
            content.text += block["text"] as? String ?? ""
            content.thinking += block["thinking"] as? String ?? ""
        case "content_block_delta":
            guard let index = object["index"] as? Int, openBlocks.contains(index), var block = blocks[index],
                  let delta = object["delta"] as? [String: Any] else { throw LanguageModelError.unreadable }
            switch delta["type"] as? String {
            case "text_delta":
                let text = delta["text"] as? String ?? ""
                block["text"] = (block["text"] as? String ?? "") + text
                content.text += text
            case "thinking_delta":
                let text = delta["thinking"] as? String ?? ""
                block["thinking"] = (block["thinking"] as? String ?? "") + text
                content.thinking += text
            case "signature_delta": block["signature"] = (block["signature"] as? String ?? "") + (delta["signature"] as? String ?? "")
            case "input_json_delta": inputs[index, default: ""] += delta["partial_json"] as? String ?? ""
            default: break
            }
            blocks[index] = block
        case "content_block_stop":
            guard let index = object["index"] as? Int, openBlocks.remove(index) != nil else { throw LanguageModelError.unreadable }
            if let input = inputs[index], !input.isEmpty {
                guard let parsed = try JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any] else { throw LanguageModelError.unreadable }
                blocks[index]?["input"] = parsed
            }
        case "message_delta":
            if let reason = (object["delta"] as? [String: Any])?["stop_reason"] as? String {
                guard ["end_turn", "tool_use", "stop_sequence", "refusal"].contains(reason) else {
                    throw LanguageModelError.invalid("模型回复未完整生成，请缩小请求范围后重试。")
                }
                stopReason = reason
            }
        case "message_stop":
            guard started, stopReason != nil, openBlocks.isEmpty else { throw LanguageModelError.unreadable }
            finished = true
        default: break
        }
    }

    func response() throws -> Data {
        guard finished else { throw LanguageModelError.incompleteResponse(retries: 0) }
        let body: [String: Any]
        switch format {
        case .openAI:
            var message: [String: Any] = ["role": "assistant", "content": content.text]
            if !content.thinking.isEmpty { message["reasoning_content"] = content.thinking }
            if !calls.isEmpty {
                message["tool_calls"] = try calls.keys.sorted().map { index -> [String: Any] in
                    let call = calls[index]!
                    guard !call.id.isEmpty, !call.name.isEmpty,
                          (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) is [String: Any] else { throw LanguageModelError.unreadable }
                    return ["id": call.id, "type": "function", "function": ["name": call.name, "arguments": call.arguments]]
                }
            }
            body = ["choices": [["message": message]]]
        case .anthropic: body = ["content": blocks.keys.sorted().compactMap { blocks[$0] }]
        }
        return try JSONSerialization.data(withJSONObject: body)
    }
}
