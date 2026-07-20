import Foundation

/// OpenAI Chat Completions 客户端（/v1/chat/completions）。
/// 请求体按较新模型习惯：content 为 text parts，system→developer，
/// 并带 verbosity / reasoning_effort；实现 DeepSeekService 以便复用现有调用链。
actor OpenAIClient {
    private let keyProvider: @Sendable () -> String
    private let baseURL: URL
    private let session: URLSession
    private let timeoutInterval: TimeInterval
    private let verbosity: String
    private let reasoningEffort: String

    init(
        keyProvider: @escaping @Sendable () -> String,
        baseURL: URL = LLMProvider.openai.chatCompletionsURL,
        session: URLSession = .shared,
        timeoutInterval: TimeInterval = 30,
        verbosity: String = "medium",
        reasoningEffort: String = "medium"
    ) {
        self.keyProvider = keyProvider
        self.baseURL = baseURL
        self.session = session
        self.timeoutInterval = timeoutInterval
        self.verbosity = verbosity
        self.reasoningEffort = reasoningEffort
    }

    init(
        apiKey: String,
        baseURL: URL = LLMProvider.openai.chatCompletionsURL,
        session: URLSession = .shared,
        timeoutInterval: TimeInterval = 30
    ) {
        self.init(keyProvider: { apiKey }, baseURL: baseURL, session: session, timeoutInterval: timeoutInterval)
    }

    func chat(
        model: String = LLMProvider.openai.defaultModel,
        messages: [[String: String]],
        temperature: Double = 0.7,
        maxTokens: Int = 2000,
        timeoutInterval: TimeInterval = 30
    ) async throws -> (content: String, usage: TokenUsage) {
        let maxAttempts = 3
        var lastError: Error?
        for attempt in 0..<maxAttempts {
            try Task.checkCancellation()
            do {
                return try await performRequest(
                    model: model,
                    messages: messages,
                    maxTokens: maxTokens,
                    timeoutInterval: timeoutInterval,
                    stream: false
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                guard Self.isRetryable(error), attempt < maxAttempts - 1 else { throw error }
                let backoff = pow(2.0, Double(attempt)) * 0.5
                let jitter = Double.random(in: 0...0.25)
                try await Task.sleep(nanoseconds: UInt64((backoff + jitter) * 1_000_000_000))
            }
        }
        throw lastError ?? DeepSeekClientError.invalidResponse
    }

    func chatStream(
        model: String = LLMProvider.openai.defaultModel,
        messages: [[String: String]],
        temperature: Double = 0.7,
        maxTokens: Int = 2000,
        timeoutInterval: TimeInterval = 30,
        onToken: @escaping @Sendable (String) async -> Void
    ) async throws -> TokenUsage {
        let maxAttempts = 3
        var lastError: Error?
        for attempt in 0..<maxAttempts {
            try Task.checkCancellation()
            do {
                return try await performStreamRequest(
                    model: model,
                    messages: messages,
                    maxTokens: maxTokens,
                    timeoutInterval: timeoutInterval,
                    onToken: onToken
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                guard Self.isRetryable(error), attempt < maxAttempts - 1 else { throw error }
                let backoff = pow(2.0, Double(attempt)) * 0.5
                let jitter = Double.random(in: 0...0.25)
                try await Task.sleep(nanoseconds: UInt64((backoff + jitter) * 1_000_000_000))
            }
        }
        throw lastError ?? DeepSeekClientError.invalidResponse
    }

    private static func isRetryable(_ error: Error) -> Bool {
        switch error {
        case DeepSeekClientError.httpError(let status, _):
            return status >= 500
        case DeepSeekClientError.networkError(let underlying):
            if let urlError = underlying as? URLError {
                switch urlError.code {
                case .timedOut, .networkConnectionLost, .notConnectedToInternet,
                     .cannotConnectToHost, .dnsLookupFailed:
                    return true
                default: return false
                }
            }
            return false
        default: return false
        }
    }

    private func makeBody(
        model: String,
        messages: [[String: String]],
        maxTokens: Int,
        stream: Bool
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "messages": Self.openaiMessages(from: messages),
            "response_format": ["type": "text"],
            "verbosity": verbosity,
            "reasoning_effort": reasoningEffort,
            "store": false,
            "max_completion_tokens": maxTokens,
        ]
        if stream {
            body["stream"] = true
            body["stream_options"] = ["include_usage": true]
        }
        return body
    }

    /// 把内部 `[[role:content]]` 转成 OpenAI 新格式；`system` → `developer`。
    private static func openaiMessages(from messages: [[String: String]]) -> [[String: Any]] {
        messages.map { msg in
            let role = msg["role"] == "system" ? "developer" : (msg["role"] ?? "user")
            let text = msg["content"] ?? ""
            return [
                "role": role,
                "content": [
                    ["type": "text", "text": text],
                ],
            ]
        }
    }

    private func performRequest(
        model: String,
        messages: [[String: String]],
        maxTokens: Int,
        timeoutInterval: TimeInterval,
        stream: Bool
    ) async throws -> (content: String, usage: TokenUsage) {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(keyProvider())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeoutInterval
        request.httpBody = try JSONSerialization.data(
            withJSONObject: makeBody(model: model, messages: messages, maxTokens: maxTokens, stream: stream)
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw DeepSeekClientError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DeepSeekClientError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw DeepSeekClientError.httpError(statusCode: httpResponse.statusCode, body: body)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DeepSeekClientError.invalidResponse
        }

        guard let content = Self.extractContent(from: json) else {
            throw DeepSeekClientError.missingContent
        }

        let usage = Self.extractUsage(from: json)
        return (content, usage)
    }

    private func performStreamRequest(
        model: String,
        messages: [[String: String]],
        maxTokens: Int,
        timeoutInterval: TimeInterval,
        onToken: @escaping @Sendable (String) async -> Void
    ) async throws -> TokenUsage {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(keyProvider())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeoutInterval
        request.httpBody = try JSONSerialization.data(
            withJSONObject: makeBody(model: model, messages: messages, maxTokens: maxTokens, stream: true)
        )

        let (bytes, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DeepSeekClientError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            var errBody = Data()
            for try await byte in bytes { errBody.append(byte) }
            let body = String(data: errBody, encoding: .utf8) ?? ""
            throw DeepSeekClientError.httpError(statusCode: httpResponse.statusCode, body: body)
        }

        var lineBuffer = Data()
        var usage = TokenUsage(promptTokens: 0, completionTokens: 0, totalTokens: 0)
        var accumulated = ""
        var lastFlush = Date()

        for try await byte in bytes {
            lineBuffer.append(byte)
            if byte != 0x0A { continue }

            guard let line = String(data: lineBuffer, encoding: .utf8) else {
                lineBuffer = Data()
                continue
            }
            lineBuffer = Data()

            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed == "data: [DONE]" { break }
            guard trimmed.hasPrefix("data: ") else { continue }
            let payload = String(trimmed.dropFirst(6))

            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            if let usageDict = json["usage"] as? [String: Any] {
                usage = TokenUsage(
                    promptTokens: (usageDict["prompt_tokens"] as? Int) ?? 0,
                    completionTokens: (usageDict["completion_tokens"] as? Int) ?? 0,
                    totalTokens: (usageDict["total_tokens"] as? Int) ?? 0
                )
            }

            guard let choices = json["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any] else { continue }

            if let text = Self.extractText(from: delta) {
                accumulated += text
                if accumulated.count >= 20 || Date().timeIntervalSince(lastFlush) > 0.15 {
                    await onToken(accumulated)
                    accumulated = ""
                    lastFlush = Date()
                }
            }
        }

        if !accumulated.isEmpty {
            await onToken(accumulated)
        }

        return usage
    }

    /// 从非流式响应取文本：支持 `content: "str"` 或 `content: [{type,text}]`。
    private static func extractContent(from json: [String: Any]) -> String? {
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            return nil
        }
        return extractText(from: message)
    }

    private static func extractText(from container: [String: Any]) -> String? {
        if let content = container["content"] as? String {
            return content
        }
        if let parts = container["content"] as? [[String: Any]] {
            let texts = parts.compactMap { part -> String? in
                if let text = part["text"] as? String { return text }
                return nil
            }
            let joined = texts.joined()
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    private static func extractUsage(from json: [String: Any]) -> TokenUsage {
        guard let usageDict = json["usage"] as? [String: Any] else {
            return TokenUsage(promptTokens: 0, completionTokens: 0, totalTokens: 0)
        }
        return TokenUsage(
            promptTokens: (usageDict["prompt_tokens"] as? Int) ?? 0,
            completionTokens: (usageDict["completion_tokens"] as? Int) ?? 0,
            totalTokens: (usageDict["total_tokens"] as? Int) ?? 0
        )
    }
}

extension OpenAIClient: DeepSeekService {}
