import Foundation
import Testing
@testable import TrainingApp

private enum TestError: Error {
    case message(String)
}

private extension InputStream {
    func readAll() throws -> Data {
        open()
        defer { close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while hasBytesAvailable {
            let count = read(&buffer, maxLength: buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
            } else if count < 0 {
                throw streamError ?? TestError.message("Stream read failed")
            } else {
                break
            }
        }
        return data
    }
}

private final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responseHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.absoluteString.hasPrefix("https://api.deepseek.com") == true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        guard let handler = Self.responseHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@Suite("DeepSeekClient", .serialized)
struct DeepSeekClientTests {

    private func makeClient(
        apiKey: String = "sk-test-key",
        timeoutInterval: TimeInterval = 30,
        handler: @Sendable @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> DeepSeekClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.responseHandler = handler
        return DeepSeekClient(
            apiKey: apiKey,
            session: URLSession(configuration: config),
            timeoutInterval: timeoutInterval
        )
    }

    private let testMessages: [[String: String]] = [
        ["role": "system", "content": "You are a fitness trainer."],
        ["role": "user", "content": "What's a good workout?"],
    ]

    private func successJSON(content: String) -> Data {
        """
        {"id":"cmpl-abc","choices":[{"message":{"role":"assistant","content":"\(content)"}}],"usage":{"prompt_tokens":42,"completion_tokens":128,"total_tokens":170}}
        """.data(using: .utf8)!
    }

    private func makeResponse(request: URLRequest?, statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request?.url ?? URL(string: "https://api.deepseek.com/chat/completions")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    // MARK: - Request Construction

    @Test("request has Authorization and Content-Type headers")
    func testRequestHeaders() async throws {
        let client = makeClient { request in
            return (self.makeResponse(request: request, statusCode: 200), self.successJSON(content: "ok"))
        }
        _ = try? await client.chat(messages: testMessages)
        let request = try #require(MockURLProtocol.lastRequest)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test-key")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test("request body has model, messages, temperature, max_tokens")
    func testRequestBody() async throws {
        let client = makeClient { request in
            return (self.makeResponse(request: request, statusCode: 200), self.successJSON(content: "ok"))
        }
        _ = try? await client.chat(
            model: "deepseek-chat",
            messages: testMessages,
            temperature: 0.7,
            maxTokens: 2000
        )
        let request = try #require(MockURLProtocol.lastRequest)
        let body: Data
        if let httpBody = request.httpBody {
            body = httpBody
        } else if let stream = request.httpBodyStream {
            body = try stream.readAll()
        } else {
            throw TestError.message("No request body found")
        }
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "deepseek-chat")
        #expect(json["temperature"] as? Double == 0.7)
        #expect(json["max_tokens"] as? Int == 2000)

        let messages = try #require(json["messages"] as? [[String: String]])
        #expect(messages.count == 2)
        #expect(messages[0]["role"] == "system")
        #expect(messages[0]["content"] == "You are a fitness trainer.")
        #expect(messages[1]["role"] == "user")
        #expect(messages[1]["content"] == "What's a good workout?")
    }

    // MARK: - Response Parsing

    @Test("parse success response returns content and token usage")
    func testParseSuccessResponse() async throws {
        let client = makeClient { request in
            return (self.makeResponse(request: request, statusCode: 200), self.successJSON(content: "Try a 20-minute HIIT session today!"))
        }
        let (content, usage) = try await client.chat(messages: testMessages)
        #expect(content == "Try a 20-minute HIIT session today!")
        #expect(usage.promptTokens == 42)
        #expect(usage.completionTokens == 128)
        #expect(usage.totalTokens == 170)
    }

    @Test("parse error response throws httpError with status code and body")
    func testParseErrorResponse() async throws {
        let errorBody = """
        {"error": {"message": "Invalid API key"}}
        """
        let client = makeClient { request in
            return (self.makeResponse(request: request, statusCode: 401), errorBody.data(using: .utf8)!)
        }

        do {
            _ = try await client.chat(messages: testMessages)
            #expect(Bool(false), "Expected error not thrown")
        } catch {
            guard case let DeepSeekClientError.httpError(statusCode, body) = error else {
                #expect(Bool(false), "Unexpected error type: \(error)")
                return
            }
            #expect(statusCode == 401)
            #expect(body.contains("Invalid API key"))
        }
    }

    @Test("parse malformed JSON throws invalidResponse")
    func testParseMalformedJSON() async throws {
        let client = makeClient { request in
            return (self.makeResponse(request: request, statusCode: 200), "not json".data(using: .utf8)!)
        }

        do {
            _ = try await client.chat(messages: testMessages)
            #expect(Bool(false), "Expected error not thrown")
        } catch {
            #expect(error is DeepSeekClientError)
        }
    }

    @Test("response with missing content in choices throws missingContent")
    func testParseMissingContent() async throws {
        let client = makeClient { request in
            let body = """
            {"choices":[],"usage":{"prompt_tokens":1,"completion_tokens":0,"total_tokens":1}}
            """.data(using: .utf8)!
            return (self.makeResponse(request: request, statusCode: 200), body)
        }

        do {
            _ = try await client.chat(messages: testMessages)
            #expect(Bool(false), "Expected error not thrown")
        } catch {
            guard case DeepSeekClientError.missingContent = error else {
                #expect(Bool(false), "Unexpected error type: \(error)")
                return
            }
        }
    }

    @Test("timeout throws networkError")
    func testTimeout() async throws {
        let client = makeClient(timeoutInterval: 0.1) { _ in
            throw URLError(.timedOut)
        }

        do {
            _ = try await client.chat(messages: testMessages)
            #expect(Bool(false), "Expected error not thrown")
        } catch {
            guard case let DeepSeekClientError.networkError(underlying) = error else {
                #expect(Bool(false), "Unexpected error type: \(error)")
                return
            }
            let urlError = underlying as? URLError
            #expect(urlError?.code == .timedOut)
        }
    }

    @Test("4xx errors are not retried")
    func testNoRetryOn4xx() async throws {
        nonisolated(unsafe) var callCount = 0
        let client = makeClient { request in
            callCount += 1
            let body = "{\"error\":\"bad request\"}".data(using: .utf8)!
            return (self.makeResponse(request: request, statusCode: 400), body)
        }
        do {
            _ = try await client.chat(messages: testMessages)
        } catch {
        }
        #expect(callCount == 1)
    }

    @Test("response without usage field defaults to zero tokens")
    func testUsageOptionalDefaultsZero() async throws {
        let client = makeClient { request in
            let body = """
            {"id":"cmpl-abc","choices":[{"message":{"role":"assistant","content":"ok"}}]}
            """.data(using: .utf8)!
            return (self.makeResponse(request: request, statusCode: 200), body)
        }
        let (content, usage) = try await client.chat(messages: testMessages)
        #expect(content == "ok")
        #expect(usage.totalTokens == 0)
        #expect(usage.promptTokens == 0)
        #expect(usage.completionTokens == 0)
    }

    @Test("chatStream default delegates to chat and fires onToken")
    func testChatStreamDefault() async throws {
        let service = ChatOnlyService()
        service.responseContent = "Hello World"
        service.responseUsage = TokenUsage(promptTokens: 10, completionTokens: 5, totalTokens: 15)

        nonisolated(unsafe) var tokens: [String] = []
        let usage = try await service.chatStream(
            model: "", messages: [], temperature: 0, maxTokens: 0, timeoutInterval: 0,
            onToken: { t in tokens.append(t) }
        )

        #expect(tokens.count == 1)
        #expect(tokens[0] == "Hello World")
        #expect(usage.totalTokens == 15)
    }

    @Test("chatStream parses usage from final chunk with empty choices")
    func testChatStreamParsesUsageFromFinalChunk() async throws {
        // Real DeepSeek streaming: content deltas followed by a final chunk
        // whose choices array is empty and usage carries the real token counts.
        // This only happens when stream_options.include_usage is set.
        let sse = """
        data: {"choices":[{"delta":{"content":"Hi"}}]}

        data: {"choices":[{"delta":{"content":" there"}}]}

        data: {"choices":[],"usage":{"prompt_tokens":42,"completion_tokens":128,"total_tokens":170}}

        data: [DONE]

        """.data(using: .utf8)!

        let client = makeClient { request in
            return (self.makeResponse(request: request, statusCode: 200), sse)
        }

        nonisolated(unsafe) var tokens: [String] = []
        let usage = try await client.chatStream(
            model: "deepseek-chat",
            messages: testMessages,
            temperature: 0.7,
            maxTokens: 2000,
            timeoutInterval: 30,
            onToken: { t in tokens.append(t) }
        )

        #expect(usage.promptTokens == 42)
        #expect(usage.completionTokens == 128)
        #expect(usage.totalTokens == 170)
        // both deltas flushed (may batch into one token due to flush threshold)
        let joined = tokens.joined()
        #expect(joined == "Hi there")
    }

    @Test("chatStream request body includes stream_options include_usage")
    func testChatStreamRequestIncludesUsageOption() async throws {
        let client = makeClient { request in
            let sse = "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":0,\"completion_tokens\":0,\"total_tokens\":0}}\n\ndata: [DONE]\n\n".data(using: .utf8)!
            return (self.makeResponse(request: request, statusCode: 200), sse)
        }
        _ = try? await client.chatStream(
            model: "deepseek-chat", messages: testMessages,
            temperature: 0.7, maxTokens: 2000, timeoutInterval: 30,
            onToken: { _ in }
        )
        let request = try #require(MockURLProtocol.lastRequest)
        let body: Data
        if let httpBody = request.httpBody {
            body = httpBody
        } else if let stream = request.httpBodyStream {
            body = try stream.readAll()
        } else {
            throw TestError.message("No request body found")
        }
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let streamOptions = try #require(json["stream_options"] as? [String: Any])
        #expect(streamOptions["include_usage"] as? Bool == true)
    }
}

private final class ChatOnlyService: DeepSeekService, @unchecked Sendable {
    var responseContent = ""
    var responseUsage = TokenUsage(promptTokens: 0, completionTokens: 0, totalTokens: 0)

    func chat(model: String, messages: [[String: String]], temperature: Double, maxTokens: Int, timeoutInterval: TimeInterval) async throws -> (content: String, usage: TokenUsage) {
        (responseContent, responseUsage)
    }
}
