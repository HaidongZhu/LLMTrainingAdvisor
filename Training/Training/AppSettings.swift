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
        Self.migrateSecretsIfNeeded()
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

    /// 首启迁移：Keychain 为空且 Secrets 含有效 key（本地开发）时导入一次，保证已有安装无缝过渡。
    private static func migrateSecretsIfNeeded() {
        guard KeychainStore.read(forKey: AppConfig.apiKeyAccount) == nil else { return }
        let secret = Secrets.deepSeekAPIKey
        guard secret.hasPrefix("sk-") else { return }
        KeychainStore.save(secret, forKey: AppConfig.apiKeyAccount)
    }
}
