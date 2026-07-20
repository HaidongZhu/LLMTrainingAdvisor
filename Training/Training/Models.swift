import Foundation

struct ChatMessage: Codable, Identifiable {
    let id: UUID
    let role: String
    var content: String
    var fullRequest: String
    var tokenIn: Int
    var tokenOut: Int
    var cost: Double
    let createdAt: Date
}

struct PlannerResponse: Codable {
    let tools: [PlannedTool]
    let promptTemplate: String

    enum CodingKeys: String, CodingKey {
        case tools
        case promptTemplate = "prompt_template"
    }
}

struct ActivityLog: Codable, Identifiable {
    var id: UUID
    var date: Date
    var type: String
    var durationMin: Double?
    var distanceKm: Double?
    var intensity: String?
    var notes: String?
    var createdAt: Date
}

struct UserProfile: Codable {
    let key: String
    let value: String
}

struct TokenUsage: Codable {
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }
}

enum LLMProvider: String, CaseIterable, Identifiable, Sendable {
    case deepseek
    case openai

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .deepseek: return "DeepSeek"
        case .openai: return "OpenAI"
        }
    }

    var defaultModel: String {
        switch self {
        case .deepseek: return "deepseek-v4-pro"
        case .openai: return "gpt-5.4-mini"
        }
    }

    var apiKeyAccount: String {
        switch self {
        case .deepseek: return "deepseek_api_key"
        case .openai: return "openai_api_key"
        }
    }

    var modelDefaultsKey: String {
        switch self {
        case .deepseek: return "deepseek_model"
        case .openai: return "openai_model"
        }
    }

    var chatCompletionsURL: URL {
        switch self {
        case .deepseek: return URL(string: "https://api.deepseek.com/chat/completions")!
        case .openai: return URL(string: "https://api.openai.com/v1/chat/completions")!
        }
    }
}

enum AppConfig {
    static let providerDefaultsKey = "llm_provider"
    static let isSelfTestMode = false

    /// 兼容旧代码：默认 DeepSeek 模型名。
    static let defaultModel = LLMProvider.deepseek.defaultModel
    static let apiKeyAccount = LLMProvider.deepseek.apiKeyAccount
    static let modelDefaultsKey = LLMProvider.deepseek.modelDefaultsKey

    /// 当前选中的 LLM 提供商（UserDefaults）。
    static var provider: LLMProvider {
        get {
            let raw = UserDefaults.standard.string(forKey: providerDefaultsKey) ?? LLMProvider.deepseek.rawValue
            return LLMProvider(rawValue: raw) ?? .deepseek
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: providerDefaultsKey)
        }
    }

    /// 当前提供商的 API Key（Keychain，线程安全只读）。
    static var apiKey: String {
        KeychainStore.read(forKey: provider.apiKeyAccount) ?? ""
    }

    /// 当前提供商的模型名（UserDefaults）。
    static var model: String {
        UserDefaults.standard.string(forKey: provider.modelDefaultsKey) ?? provider.defaultModel
    }

    /// 兼容旧调用点。
    static var deepSeekAPIKey: String { apiKey }
    static var deepSeekModel: String { model }

    /// 按当前设置构造可用的 LLM 客户端。
    static func makeLLMClient() -> DeepSeekService {
        switch provider {
        case .deepseek:
            return DeepSeekClient(keyProvider: { AppConfig.apiKey })
        case .openai:
            return OpenAIClient(keyProvider: { AppConfig.apiKey })
        }
    }
}

/// 每次请求按当前 AppConfig.provider 转发，设置页切换后无需重启即可生效。
final class CurrentLLMClient: DeepSeekService, @unchecked Sendable {
    func chat(
        model: String,
        messages: [[String: String]],
        temperature: Double,
        maxTokens: Int,
        timeoutInterval: TimeInterval
    ) async throws -> (content: String, usage: TokenUsage) {
        try await AppConfig.makeLLMClient().chat(
            model: model,
            messages: messages,
            temperature: temperature,
            maxTokens: maxTokens,
            timeoutInterval: timeoutInterval
        )
    }

    func chatStream(
        model: String,
        messages: [[String: String]],
        temperature: Double,
        maxTokens: Int,
        timeoutInterval: TimeInterval,
        onToken: @escaping @Sendable (String) async -> Void
    ) async throws -> TokenUsage {
        try await AppConfig.makeLLMClient().chatStream(
            model: model,
            messages: messages,
            temperature: temperature,
            maxTokens: maxTokens,
            timeoutInterval: timeoutInterval,
            onToken: onToken
        )
    }
}

struct MatchSchedule: Codable, Identifiable {
    var id: UUID
    var date: Date
    var time: String?
    var opponent: String?
    var intensity: String?
    var notes: String?
    var actualDurationMin: Double?
    var actualIntensity: String?
    var isCompleted: Bool
    var createdAt: Date
}
