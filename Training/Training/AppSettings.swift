import Foundation

/// 设置页的 UI 状态包装。真相源是 Keychain（API Key）和 UserDefaults（模型）。
/// AppConfig 从相同存储读取，保证 DeepSeekClient 与设置页数据一致。
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private(set) var apiKey: String
    var model: String {
        didSet { UserDefaults.standard.set(model, forKey: AppConfig.modelDefaultsKey) }
    }

    private init() {
        if let stored = KeychainStore.read(forKey: AppConfig.apiKeyAccount),
           stored == "sk-749179de25204853b06233beba10e945" {
            KeychainStore.delete(forKey: AppConfig.apiKeyAccount)
        }
        self.apiKey = KeychainStore.read(forKey: AppConfig.apiKeyAccount) ?? ""
        self.model = UserDefaults.standard.string(forKey: AppConfig.modelDefaultsKey) ?? AppConfig.defaultModel
    }

    var hasAPIKey: Bool { !apiKey.isEmpty }

    /// 脱敏展示，如 "sk-...e945"。空则返回占位。
    var maskedKey: String {
        guard !apiKey.isEmpty else { return "未配置" }
        guard apiKey.count > 7 else { return "sk-***" }
        return "\(apiKey.prefix(3))...\(apiKey.suffix(4))"
    }

    /// 保存 key 到 Keychain，立即生效（DeepSeekClient 下次请求即读到新值）。
    @discardableResult
    func saveAPIKey(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let ok = KeychainStore.save(trimmed, forKey: AppConfig.apiKeyAccount)
        if ok { apiKey = trimmed }
        return ok
    }

    /// 清除 key。
    @discardableResult
    func clearAPIKey() -> Bool {
        let ok = KeychainStore.delete(forKey: AppConfig.apiKeyAccount)
        if ok { apiKey = "" }
        return ok
    }

}
