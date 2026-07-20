import Foundation

/// 设置页的 UI 状态包装。真相源是 Keychain（API Key）和 UserDefaults（模型 / 提供商）。
/// AppConfig 从相同存储读取，保证 LLM Client 与设置页数据一致。
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    var provider: LLMProvider {
        didSet {
            AppConfig.provider = provider
            reloadForCurrentProvider()
        }
    }

    private(set) var apiKey: String
    var model: String {
        didSet { UserDefaults.standard.set(model, forKey: provider.modelDefaultsKey) }
    }

    private init() {
        if let stored = KeychainStore.read(forKey: LLMProvider.deepseek.apiKeyAccount),
           stored == "sk-749179de25204853b06233beba10e945" {
            KeychainStore.delete(forKey: LLMProvider.deepseek.apiKeyAccount)
        }
        let current = AppConfig.provider
        self.provider = current
        self.apiKey = KeychainStore.read(forKey: current.apiKeyAccount) ?? ""
        self.model = UserDefaults.standard.string(forKey: current.modelDefaultsKey) ?? current.defaultModel
    }

    /// 开发辅助：通过环境变量把 Key 写入模拟器/设备 Keychain（仅当对应 env 非空时生效）。
    /// - SEED_OPENAI_API_KEY / SEED_DEEPSEEK_API_KEY
    /// - SEED_LLM_PROVIDER=openai|deepseek（可选，默认在写入 OpenAI key 时切到 openai）
    static func seedKeysFromEnvironmentIfNeeded() {
        let env = ProcessInfo.processInfo.environment
        if let key = env["SEED_OPENAI_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !key.isEmpty {
            KeychainStore.save(key, forKey: LLMProvider.openai.apiKeyAccount)
            if env["SEED_LLM_PROVIDER"] == nil {
                AppConfig.provider = .openai
            }
        }
        if let key = env["SEED_DEEPSEEK_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !key.isEmpty {
            KeychainStore.save(key, forKey: LLMProvider.deepseek.apiKeyAccount)
        }
        if let raw = env["SEED_LLM_PROVIDER"], let provider = LLMProvider(rawValue: raw) {
            AppConfig.provider = provider
        }
    }

    var hasAPIKey: Bool { !apiKey.isEmpty }

    /// 脱敏展示，如 "sk-...e945"。空则返回占位。
    var maskedKey: String {
        guard !apiKey.isEmpty else { return "未配置" }
        guard apiKey.count > 7 else { return "sk-***" }
        return "\(apiKey.prefix(3))...\(apiKey.suffix(4))"
    }

    /// 切换提供商后刷新 key / model 展示。
    func reloadForCurrentProvider() {
        apiKey = KeychainStore.read(forKey: provider.apiKeyAccount) ?? ""
        model = UserDefaults.standard.string(forKey: provider.modelDefaultsKey) ?? provider.defaultModel
    }

    /// 保存当前提供商的 key 到 Keychain，立即生效。
    @discardableResult
    func saveAPIKey(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let ok = KeychainStore.save(trimmed, forKey: provider.apiKeyAccount)
        if ok { apiKey = trimmed }
        return ok
    }

    /// 清除当前提供商的 key。
    @discardableResult
    func clearAPIKey() -> Bool {
        let ok = KeychainStore.delete(forKey: provider.apiKeyAccount)
        if ok { apiKey = "" }
        return ok
    }
}
