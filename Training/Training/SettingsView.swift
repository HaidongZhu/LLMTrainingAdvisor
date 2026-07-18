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
    /// 通过 Face ID / 触控 ID / 设备密码后，才允许查看或修改完整 Key。
    @State private var isKeyUnlocked = false
    @State private var isAuthenticating = false
    @State private var revealKeyPlaintext = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("提供商", selection: Binding(
                        get: { settings.provider },
                        set: { newValue in
                            settings.provider = newValue
                            lockKeyEditor()
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
                    HStack {
                        Text("当前状态").foregroundColor(.secondary)
                        Spacer()
                        Text(settings.hasAPIKey ? settings.maskedKey : "未配置")
                            .foregroundColor(settings.hasAPIKey ? .primary : .orange)
                            .font(.callout.monospaced())
                    }

                    if isKeyUnlocked {
                        Group {
                            if revealKeyPlaintext {
                                TextField("sk-...", text: $keyInput)
                            } else {
                                SecureField("sk-...", text: $keyInput)
                            }
                        }
                        .noAutoCapitalize()
                        .autocorrectionDisabled()
                        .textContentType(.password)
                        .font(.body.monospaced())

                        Toggle("显示完整 Key", isOn: $revealKeyPlaintext)

                        Button {
                            lockKeyEditor()
                        } label: {
                            Label("锁定 Key", systemImage: "lock.fill")
                        }
                    } else {
                        Button {
                            Task { await unlockKeyEditor() }
                        } label: {
                            HStack {
                                Label(
                                    "使用\(BiometricAuth.biometryDisplayName)解锁",
                                    systemImage: "faceid"
                                )
                                if isAuthenticating {
                                    Spacer()
                                    ProgressView().scaleEffect(0.8)
                                }
                            }
                        }
                        .disabled(isAuthenticating || !BiometricAuth.canAuthenticate)
                    }
                } header: {
                    Text("\(settings.provider.displayName) API Key")
                } footer: {
                    Text("Key 加密存储于设备 Keychain。查看或修改完整 Key 需通过 \(BiometricAuth.biometryDisplayName) 或设备密码验证。")
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
                    .disabled(!isKeyUnlocked && modelUnchanged)

                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack {
                            Label("测试连接", systemImage: "bolt.horizontal.circle")
                            if isTesting { Spacer(); ProgressView().scaleEffect(0.8) }
                        }
                    }
                    .disabled(isTesting || !canUseStoredOrInputKey)

                    if settings.provider == .deepseek {
                        Button {
                            Task { await checkBalance() }
                        } label: {
                            HStack {
                                Label("查询余额", systemImage: "yensign.circle")
                                if isCheckingBalance { Spacer(); ProgressView().scaleEffect(0.8) }
                            }
                        }
                        .disabled(isCheckingBalance || !canUseStoredOrInputKey)
                    }

                    if settings.hasAPIKey {
                        Button(role: .destructive) {
                            Task { await clearKeyAfterAuth() }
                        } label: {
                            Label("清除 Key", systemImage: "trash")
                        }
                        .disabled(isAuthenticating)
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
                lockKeyEditor()
                modelInput = settings.model
            }
            .onDisappear {
                lockKeyEditor()
            }
        }
    }

    private var modelUnchanged: Bool {
        let trimmed = modelInput.trimmingCharacters(in: .whitespaces)
        let effective = trimmed.isEmpty ? settings.provider.defaultModel : trimmed
        return effective == settings.model
    }

    /// 已解锁且输入了新 Key，或已有存储 Key（测试/余额可不露出明文）。
    private var canUseStoredOrInputKey: Bool {
        if isKeyUnlocked, !keyInput.trimmingCharacters(in: .whitespaces).isEmpty {
            return true
        }
        return settings.hasAPIKey
    }

    private func resolveKeyForRequest() -> String {
        let typed = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if isKeyUnlocked, !typed.isEmpty { return typed }
        return settings.apiKey
    }

    private func unlockKeyEditor() async {
        isAuthenticating = true
        statusMessage = ""
        defer { isAuthenticating = false }
        do {
            try await BiometricAuth.authenticateToUnlockAPIKey()
            isKeyUnlocked = true
            keyInput = settings.apiKey
            statusIsError = false
            statusMessage = "已解锁，可查看或修改 Key"
        } catch {
            statusIsError = true
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func lockKeyEditor() {
        isKeyUnlocked = false
        revealKeyPlaintext = false
        keyInput = ""
    }

    private func save() {
        let trimmedModel = modelInput.trimmingCharacters(in: .whitespaces)
        settings.model = trimmedModel.isEmpty ? settings.provider.defaultModel : trimmedModel

        if isKeyUnlocked {
            let typed = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !typed.isEmpty {
                settings.saveAPIKey(typed)
            }
            lockKeyEditor()
        }

        statusMessage = ""
        showSaved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showSaved = false }
    }

    private func clearKeyAfterAuth() async {
        if !isKeyUnlocked {
            isAuthenticating = true
            defer { isAuthenticating = false }
            do {
                try await BiometricAuth.authenticateToUnlockAPIKey()
            } catch {
                statusIsError = true
                statusMessage = "❌ \(error.localizedDescription)"
                return
            }
        }
        settings.clearAPIKey()
        lockKeyEditor()
        statusMessage = "已清除 API Key"
        statusIsError = false
    }

    /// DeepSeek 用 balance 接口；OpenAI 用一次极短 chat 验证密钥。
    private func testConnection() async {
        isTesting = true
        statusMessage = ""
        let key = resolveKeyForRequest()
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
        let key = resolveKeyForRequest()
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
