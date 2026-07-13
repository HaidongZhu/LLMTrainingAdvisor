import Foundation

enum DeepSeekClientError: LocalizedError {
    case networkError(Error)
    case httpError(statusCode: Int, body: String)
    case invalidResponse
    case missingContent
    case decodingError(Error)

    var errorDescription: String? {
        switch self {
        case .networkError(let e): return "网络错误: \(e.localizedDescription)"
        case .httpError(let code, let body): return "HTTP \(code): \(body)"
        case .invalidResponse: return "无效响应"
        case .missingContent: return "响应无内容"
        case .decodingError(let e): return "解析错误: \(e.localizedDescription)"
        }
    }
}

struct DeepSeekResponse: Codable {
    struct Choice: Codable {
        struct Message: Codable {
            let role: String
            let content: String
        }
        let message: Message
    }
    let choices: [Choice]
    let usage: TokenUsage?
}

actor DeepSeekClient {
    private let keyProvider: @Sendable () -> String
    private let baseURL: URL
    private let session: URLSession
    private let timeoutInterval: TimeInterval

    init(
        keyProvider: @escaping @Sendable () -> String,
        baseURL: URL = URL(string: "https://api.deepseek.com/chat/completions")!,
        session: URLSession = .shared,
        timeoutInterval: TimeInterval = 30
    ) {
        self.keyProvider = keyProvider
        self.baseURL = baseURL
        self.session = session
        self.timeoutInterval = timeoutInterval
    }

    /// 便捷初始化：固定 key（测试用）。转发到 keyProvider 形式。
    init(
        apiKey: String,
        baseURL: URL = URL(string: "https://api.deepseek.com/chat/completions")!,
        session: URLSession = .shared,
        timeoutInterval: TimeInterval = 30
    ) {
        self.init(keyProvider: { apiKey }, baseURL: baseURL, session: session, timeoutInterval: timeoutInterval)
    }

    func chat(
        model: String = "deepseek-chat",
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
                return try await performRequest(model: model, messages: messages, temperature: temperature, maxTokens: maxTokens, timeoutInterval: timeoutInterval)
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

    private func performRequest(model: String, messages: [[String: String]], temperature: Double, maxTokens: Int, timeoutInterval: TimeInterval) async throws -> (content: String, usage: TokenUsage) {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(keyProvider())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeoutInterval

        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": temperature,
            "max_tokens": maxTokens,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

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

        let decoder = JSONDecoder()
        let result: DeepSeekResponse
        do {
            result = try decoder.decode(DeepSeekResponse.self, from: data)
        } catch {
            throw DeepSeekClientError.decodingError(error)
        }

        guard let content = result.choices.first?.message.content else {
            throw DeepSeekClientError.missingContent
        }

        let usage = result.usage ?? TokenUsage(promptTokens: 0, completionTokens: 0, totalTokens: 0)
        return (content, usage)
    }

    func chatStream(
        model: String = "deepseek-chat",
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
                return try await performStreamRequest(model: model, messages: messages, temperature: temperature, maxTokens: maxTokens, timeoutInterval: timeoutInterval, onToken: onToken)
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

    private func performStreamRequest(
        model: String,
        messages: [[String: String]],
        temperature: Double,
        maxTokens: Int,
        timeoutInterval: TimeInterval,
        onToken: @escaping @Sendable (String) async -> Void
    ) async throws -> TokenUsage {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(keyProvider())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeoutInterval

        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": temperature,
            "max_tokens": maxTokens,
            "stream": true,
            "stream_options": ["include_usage": true],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

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

            // usage chunk: arrives before [DONE] with empty choices when
            // stream_options.include_usage is set. Parse it regardless of choices.
            if let usageDict = json["usage"] as? [String: Any] {
                usage = TokenUsage(
                    promptTokens: (usageDict["prompt_tokens"] as? Int) ?? 0,
                    completionTokens: (usageDict["completion_tokens"] as? Int) ?? 0,
                    totalTokens: (usageDict["total_tokens"] as? Int) ?? 0
                )
            }

            guard let choices = json["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any] else { continue }

            if let content = delta["content"] as? String {
                accumulated += content
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
}
