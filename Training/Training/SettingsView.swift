import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    private let settings = AppSettings.shared

    @State private var keyInput: String = ""
    @State private var modelInput: String = ""
    @State private var statusMessage: String = ""
    @State private var statusIsError = false
    @State private var isTesting = false
    @State private var isCheckingBalance = false
    @State private var showSaved = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("提供商", selection: Binding(
                        get: { settings.provider },
                        set: { newValue in
                            settings.provider = newValue
                            keyInput = settings.apiKey
                            modelInput = settings.model
                            statusMessage = ""
                        }
                    )) {
                        ForEach(LLMProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("LLM 提供商")
                } footer: {
                    Text("DeepSeek 与 OpenAI 的 Key / 模型各自独立保存，切换后互不影响。")
                }

                Section {
                    SecureField("sk-...", text: $keyInput)
                        .noAutoCapitalize()
                        .autocorrectionDisabled()
                    HStack {
                        Text("当前状态").foregroundColor(.secondary)
                        Spacer()
                        Text(settings.hasAPIKey ? settings.maskedKey : "未配置")
                            .foregroundColor(settings.hasAPIKey ? .primary : .orange)
                            .font(.callout.monospaced())
                    }
                } header: {
                    Text("\(settings.provider.displayName) API Key")
                } footer: {
                    Text("Key 加密存储于设备 Keychain，保存后立即生效。")
                }

                Section("模型") {
                    TextField(settings.provider.defaultModel, text: $modelInput)
                        .noAutoCapitalize()
                        .autocorrectionDisabled()
                }

                Section {
                    Button {
                        save()
                    } label: {
                        Label(showSaved ? "已保存" : "保存", systemImage: showSaved ? "checkmark.circle.fill" : "square.and.arrow.down")
                    }

                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack {
                            Label("测试连接", systemImage: "bolt.horizontal.circle")
                            if isTesting { Spacer(); ProgressView().scaleEffect(0.8) }
                        }
                    }
                    .disabled(isTesting || keyInput.trimmingCharacters(in: .whitespaces).isEmpty)

                    if settings.provider == .deepseek {
                        Button {
                            Task { await checkBalance() }
                        } label: {
                            HStack {
                                Label("查询余额", systemImage: "yensign.circle")
                                if isCheckingBalance { Spacer(); ProgressView().scaleEffect(0.8) }
                            }
                        }
                        .disabled(isCheckingBalance || keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    if settings.hasAPIKey {
                        Button(role: .destructive) {
                            clearKey()
                        } label: {
                            Label("清除 Key", systemImage: "trash")
                        }
                    }
                }

                if !statusMessage.isEmpty {
                    Section {
                        Text(statusMessage)
                            .font(.callout)
                            .foregroundColor(statusIsError ? .red : .green)
                    }
                }

                Section("关于") {
                    LabeledContent("版本", value: AppVersion.buildHash)
                    LabeledContent("构建时间", value: AppVersion.buildTime)
                }
            }
            .navigationTitle("设置")
            .inlineNavTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear {
                keyInput = settings.apiKey
                modelInput = settings.model
            }
        }
    }

    private func save() {
        settings.saveAPIKey(keyInput)
        let trimmed = modelInput.trimmingCharacters(in: .whitespaces)
        settings.model = trimmed.isEmpty ? settings.provider.defaultModel : trimmed
        statusMessage = ""
        showSaved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showSaved = false }
    }

    private func clearKey() {
        settings.clearAPIKey()
        keyInput = ""
        statusMessage = "已清除 API Key"
        statusIsError = false
    }

    /// DeepSeek 用 balance 接口；OpenAI 用一次极短 chat 验证密钥。
    private func testConnection() async {
        isTesting = true
        statusMessage = ""
        let key = keyInput.trimmingCharacters(in: .whitespaces)
        let model = modelInput.trimmingCharacters(in: .whitespaces).isEmpty
            ? settings.provider.defaultModel
            : modelInput.trimmingCharacters(in: .whitespaces)
        do {
            switch settings.provider {
            case .deepseek:
                _ = try await CostTracker.shared.fetchBalance(apiKey: key)
            case .openai:
                let client = OpenAIClient(apiKey: key)
                _ = try await client.chat(
                    model: model,
                    messages: [["role": "user", "content": "ping"]],
                    temperature: 0,
                    maxTokens: 16,
                    timeoutInterval: 30
                )
            }
            statusIsError = false
            statusMessage = "✅ 连接正常，密钥有效"
        } catch {
            statusIsError = true
            statusMessage = "❌ \(connectionErrorText(error))"
        }
        isTesting = false
    }

    private func checkBalance() async {
        isCheckingBalance = true
        statusMessage = ""
        let key = keyInput.trimmingCharacters(in: .whitespaces)
        do {
            let balance = try await CostTracker.shared.fetchBalance(apiKey: key)
            statusIsError = false
            statusMessage = "余额 ¥\(String(format: "%.2f", balance.totalCNY))"
        } catch {
            statusIsError = true
            statusMessage = "❌ \(connectionErrorText(error))"
        }
        isCheckingBalance = false
    }

    private func connectionErrorText(_ error: Error) -> String {
        if case CostTrackerError.httpError(let code, _) = error {
            switch code {
            case 401: return "密钥无效 (401)"
            case 403: return "无权限 (403)"
            default: return "HTTP \(code)"
            }
        }
        if case CostTrackerError.networkError = error {
            return "网络错误，请检查连接"
        }
        if case DeepSeekClientError.httpError(let code, _) = error {
            switch code {
            case 401: return "密钥无效 (401)"
            case 403: return "无权限 (403)"
            default: return "HTTP \(code)"
            }
        }
        if case DeepSeekClientError.networkError = error {
            return "网络错误，请检查连接"
        }
        return error.localizedDescription
    }
}

private extension View {
    /// iOS 上禁用首字母大写；macOS 无此 API 时原样返回。
    @ViewBuilder
    func noAutoCapitalize() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never)
        #else
        self
        #endif
    }

    @ViewBuilder
    func inlineNavTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}
