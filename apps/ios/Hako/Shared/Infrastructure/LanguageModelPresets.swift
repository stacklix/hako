import Foundation

enum LanguageModelProvider: String, CaseIterable, Identifiable {
    case openAI, claude, gemini, deepSeek, kimi, miniMax
    var id: String { rawValue }
    var title: String {
        switch self {
        case .openAI: "OpenAI"
        case .claude: "Claude"
        case .gemini: "Gemini"
        case .deepSeek: "DeepSeek"
        case .kimi: "Kimi"
        case .miniMax: "MiniMax"
        }
    }
    var baseURL: String {
        switch self {
        case .openAI: "https://api.openai.com/v1"
        case .claude: "https://api.anthropic.com/v1"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta/openai"
        case .deepSeek: "https://api.deepseek.com/v1"
        case .kimi: "https://api.moonshot.ai/v1"
        case .miniMax: "https://api.minimax.io/v1"
        }
    }
    var endpoints: [(title: String, url: String)] {
        switch self {
        case .kimi: [("国际", baseURL), ("中国大陆", "https://api.moonshot.cn/v1")]
        case .miniMax: [("国际", baseURL), ("中国大陆", "https://api.minimax.cn/v1")]
        default: [("官方", baseURL)]
        }
    }
}

enum LanguageModelSpeed: String, Codable, CaseIterable, Identifiable {
    case standard, fast, ultrafast
    var id: String { rawValue }
    var title: String {
        switch self {
        case .standard: "标准"
        case .fast: "快速"
        case .ultrafast: "极速"
        }
    }
}

struct LanguageModelPreset: Identifiable {
    let provider: LanguageModelProvider
    let model: String
    let title: String
    let efforts: [String]
    let defaultEffort: String?
    var speeds: [LanguageModelSpeed] = [.standard]
    var fastModel: String? = nil
    var images = true
    var id: String { provider.rawValue + "/" + model }
    var format: LanguageModelFormat {
        provider == .openAI ? .responses : provider == .claude ? .anthropic : .openAI
    }

    // Capability choices verified against the vendors' official API documents.
    // Only currently documented values are sent; an absent setting uses the API default.
    static let all: [Self] = [
        .init(provider: .openAI, model: "gpt-6.1-sol", title: "GPT-6.1 Sol", efforts: reasoning, defaultEffort: "medium", speeds: [.standard, .fast, .ultrafast]),
        .init(provider: .openAI, model: "gpt-6-astra", title: "GPT-6 Astra", efforts: reasoning, defaultEffort: "medium", speeds: [.standard, .fast, .ultrafast]),
        .init(provider: .openAI, model: "gpt-6.1-terra", title: "GPT-6.1 Terra", efforts: ["none"] + reasoning, defaultEffort: "medium", speeds: [.standard, .fast]),
        .init(provider: .openAI, model: "gpt-6-luna", title: "GPT-6 Luna", efforts: ["none"] + reasoning, defaultEffort: "medium", speeds: [.standard, .fast]),
        .init(provider: .claude, model: "claude-opus-5-5", title: "Claude Opus 5.5", efforts: reasoning, defaultEffort: "medium", speeds: [.standard, .fast]),
        .init(provider: .claude, model: "claude-sonnet-5-5", title: "Claude Sonnet 5.5", efforts: reasoning, defaultEffort: "high"),
        .init(provider: .claude, model: "claude-haiku-5-5", title: "Claude Haiku 5.5", efforts: reasoning, defaultEffort: "medium"),
        .init(provider: .claude, model: "claude-fable-5-2", title: "Claude Fable 5.2", efforts: reasoning, defaultEffort: "high", speeds: [.standard, .fast]),
        .init(provider: .gemini, model: "gemini-4-hydrogen", title: "Gemini 4 Hydrogen", efforts: ["low", "medium", "high", "xhigh"], defaultEffort: "medium"),
        .init(provider: .gemini, model: "gemini-4-argon", title: "Gemini 4 Argon", efforts: ["low", "medium", "high"], defaultEffort: "medium"),
        .init(provider: .gemini, model: "gemini-4-carbon", title: "Gemini 4 Carbon", efforts: ["low", "medium", "high"], defaultEffort: "medium"),
        .init(provider: .deepSeek, model: "deepseek-flash", title: "DeepSeek Flash", efforts: ["none", "low", "high", "max"], defaultEffort: "high"),
        .init(provider: .deepSeek, model: "deepseek-v4-pro", title: "DeepSeek V4 Pro", efforts: ["none", "low", "high", "max"], defaultEffort: "high", images: false),
        .init(provider: .kimi, model: "kimi-k3.1-pro", title: "Kimi K3.1 Pro", efforts: ["low", "high", "max"], defaultEffort: "max", speeds: [.standard, .fast], fastModel: "kimi-k3.1-pro-highspeed"),
        .init(provider: .kimi, model: "kimi-k3", title: "Kimi K3", efforts: [], defaultEffort: nil),
        .init(provider: .miniMax, model: "MiniMax-M3.1-Flash", title: "MiniMax M3.1 Flash", efforts: reasoning, defaultEffort: "max"),
        .init(provider: .miniMax, model: "MiniMax-M3", title: "MiniMax M3", efforts: ["none", "adaptive"], defaultEffort: "adaptive", speeds: [.standard, .fast])
    ]
    private static let reasoning = ["low", "medium", "high", "xhigh", "max"]

    static func matching(_ configuration: LanguageModelConfiguration) -> Self? {
        guard let id = configuration.presetID else { return nil }
        let url = configuration.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).lowercased()
        return all.first {
            $0.id == id && $0.format == configuration.format && $0.provider.endpoints.contains(where: { $0.url.lowercased() == url }) &&
                ($0.model == configuration.model || $0.fastModel == configuration.model)
        }
    }

    func configure(_ configuration: inout LanguageModelConfiguration) {
        let sameEndpoint = provider.endpoints.contains { $0.url == configuration.baseURL }
        if !sameEndpoint {
            configuration.token = ""
        }
        configuration.format = format
        if !sameEndpoint { configuration.baseURL = provider.baseURL }
        configuration.model = model
        configuration.presetID = id
        configuration.speed = .standard
        configuration.reasoningEffort = defaultEffort
    }

    static func effortTitle(_ effort: String) -> String {
        switch effort {
        case "none": "关闭思考"
        case "low": "低"
        case "medium": "中"
        case "high": "高"
        case "xhigh": "超高"
        case "max": "最高"
        case "adaptive": "自动思考"
        default: "服务商默认"
        }
    }
}

extension LanguageModelClient {
    func applyPreset(to body: inout [String: Any]) {
        guard let preset = LanguageModelPreset.matching(configuration) else { return }
        let speed = configuration.speed ?? (configuration.model == preset.fastModel ? .fast : .standard)
        let effort = configuration.reasoningEffort
        switch preset.provider {
        case .openAI:
            body["service_tier"] = speed == .standard ? "default" : speed.rawValue
            if let effort { body["reasoning"] = ["effort": effort] }
        case .claude:
            if speed == .fast { body["speed"] = "fast" }
            if let effort { body["output_config"] = ["effort": effort] }
            body["thinking"] = ["type": "adaptive"]
            body["max_tokens"] = ["xhigh", "max"].contains(effort ?? "") ? 65_536 : 32_768
        case .gemini, .deepSeek:
            if let effort { body["reasoning_effort"] = effort }
        case .kimi:
            if speed == .fast, let model = preset.fastModel { body["model"] = model }
            if let effort { body["reasoning_effort"] = effort }
        case .miniMax:
            if preset.model == "MiniMax-M3" {
                body["service_tier"] = speed == .fast ? "priority" : "standard"
                if let effort { body["thinking"] = ["type": effort == "none" ? "disabled" : "adaptive"] }
            } else if let effort { body["reasoning_effort"] = effort }
        }
    }
}

extension LanguageModelConfiguration {
    var selectionSummary: String {
        guard let preset = LanguageModelPreset.matching(self) else { return format.title + " · " + model }
        let speedTitle = (speed ?? (model == preset.fastModel ? .fast : .standard)).title
        let effortTitle = reasoningEffort.map(LanguageModelPreset.effortTitle) ?? "服务商默认"
        return speedTitle + " · 推理：" + effortTitle
    }
}
