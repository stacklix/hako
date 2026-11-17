import Foundation

extension LanguageModelClient {
    func apiError(status: Int, data: Data) -> LanguageModelError {
        // Authentication errors already have a useful explanation and may echo a key.
        guard status != 401 && status != 403,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let error = object["error"] as? [String: Any], var message = error["message"] as? String,
              !message.isEmpty else { return .response(status) }
        let token = configuration.token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty { message = message.replacingOccurrences(of: token, with: "[凭据已隐藏]") }
        message = message.replacingOccurrences(of: #"(?i)\b(?:sk[-_]|bearer\s+)[A-Za-z0-9_.-]+"#,
                                               with: "[凭据已隐藏]", options: .regularExpression)
        if status == 400 && configuration.format == .openAI && message.lowercased().contains("responses") {
            return .rejected(status, "此模型的工具调用需要 Responses API，请选择对应的内置模型，或将自定义 API 格式改为 Responses。")
        }
        // Only display a bounded explanation locally. Request logging excludes it.
        return .rejected(status, String(message.prefix(400)))
    }
}
