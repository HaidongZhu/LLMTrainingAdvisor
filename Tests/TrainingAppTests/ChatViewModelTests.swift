import Foundation
import Testing
@testable import TrainingApp

private enum TestError: LocalizedError {
    case simulatedFailure
    var errorDescription: String? { "simulatedFailure" }
}

private final class MockDeepSeekClient: DeepSeekService, @unchecked Sendable {
    var responses: [(content: String, usage: TokenUsage)] = []
    var callCount = 0
    var messageHistory: [[[String: String]]] = []

    func chat(
        model: String,
        messages: [[String: String]],
        temperature: Double,
        maxTokens: Int,
        timeoutInterval: TimeInterval = 30
    ) async throws -> (content: String, usage: TokenUsage) {
        messageHistory.append(messages)
        let response = responses[callCount]
        callCount += 1
        return response
    }
}

private final class MockMessageStore: MessageStore {
    var savedMessages: [ChatMessage] = []

    func insertChatMessage(_ message: ChatMessage) throws { savedMessages.append(message) }
    func insertActivityLog(_ activity: ActivityLog) throws {}
    func queryRecentMessages(limit: Int) throws -> [ChatMessage] { return savedMessages }
}

private final class ThrowingService: DeepSeekService, @unchecked Sendable {
    func chat(model: String, messages: [[String: String]], temperature: Double, maxTokens: Int, timeoutInterval: TimeInterval = 30) async throws -> (content: String, usage: TokenUsage) {
        throw TestError.simulatedFailure
    }
}

private func makeTokenUsage(prompt: Int = 50, completion: Int = 100) -> TokenUsage {
    TokenUsage(promptTokens: prompt, completionTokens: completion, totalTokens: prompt + completion)
}

private func makePlannerJSON() -> String {
    """
    {
      "tools": [
        {"call_id": "rec", "name": "get_recovery_score", "params": {}},
        {"call_id": "sum7", "name": "get_daily_summary", "params": {"range": "7"}}
      ],
      "prompt_template": "恢复评分：{rec}\\n每日：{sum7}\\n\\n请分析恢复状态。"
    }
    """
}

private func makeCostTracker() -> CostTracker {
    CostTracker(config: .default, allTimeTotal: nil)
}

// MARK: - Tests

@Suite("ChatViewModel")
@MainActor
struct ChatViewModelTests {

    @MainActor
    @Test("sendMessage appends user message to messages array")
    func testSendMessageAppendsUserMessage() async throws {
        let mockClient = MockDeepSeekClient()
        mockClient.responses = [
            (content: makePlannerJSON(), usage: makeTokenUsage()),
            (content: "Your recovery looks good!", usage: makeTokenUsage()),
        ]
        let viewModel = ChatViewModel(
            deepSeekService: mockClient,
            messageStore: MockMessageStore(),
            costTracker: makeCostTracker()
        )

        await viewModel.sendMessage("How am I recovering?")

        #expect(viewModel.messages.count >= 2)
        #expect(viewModel.messages.first?.role == "user")
        #expect(viewModel.messages.first?.content == "How am I recovering?")
    }

    @MainActor
    @Test("sendMessage calls planner then executor — 2 API calls")
    func testSendMessageCallsPlannerThenExecutor() async throws {
        let mockClient = MockDeepSeekClient()
        mockClient.responses = [
            (content: makePlannerJSON(), usage: makeTokenUsage()),
            (content: "You're recovering well.", usage: makeTokenUsage()),
        ]
        let viewModel = ChatViewModel(
            deepSeekService: mockClient,
            messageStore: MockMessageStore(),
            costTracker: makeCostTracker()
        )

        await viewModel.sendMessage("How am I recovering?")

        #expect(mockClient.callCount == 2)
        #expect(mockClient.messageHistory.count == 2)

        let plannerMessages = mockClient.messageHistory[0]
        #expect(plannerMessages.first(where: { $0["role"] == "system" })?["content"] == PromptBuilder.plannerSystemPrompt())

        let executorMessages = mockClient.messageHistory[1]
        #expect(executorMessages.first(where: { $0["role"] == "system" })?["content"] == PromptBuilder.systemPrompt())
    }

    @MainActor
    @Test("planner JSON response is parsed correctly")
    func testPlannerResponseParsedCorrectly() async throws {
        let mockClient = MockDeepSeekClient()
        mockClient.responses = [
            (content: makePlannerJSON(), usage: makeTokenUsage()),
            (content: "Your RHR is below baseline, great recovery!", usage: makeTokenUsage()),
        ]
        let viewModel = ChatViewModel(
            deepSeekService: mockClient,
            messageStore: MockMessageStore(),
            costTracker: makeCostTracker()
        )

        await viewModel.sendMessage("How's my recovery?")

        let assistantMessage = viewModel.messages.last
        #expect(assistantMessage?.role == "assistant")
        #expect(assistantMessage?.content == "Your RHR is below baseline, great recovery!")
    }

    @MainActor
    @Test("executor is called with template filled using sample data")
    func testExecutorCalledWithTemplateFilled() async throws {
        let mockClient = MockDeepSeekClient()
        mockClient.responses = [
            (content: makePlannerJSON(), usage: makeTokenUsage()),
            (content: "Your HRV of 30.8 is below baseline.", usage: makeTokenUsage()),
        ]
        let viewModel = ChatViewModel(
            deepSeekService: mockClient,
            messageStore: MockMessageStore(),
            costTracker: makeCostTracker()
        )

        await viewModel.sendMessage("How's my HRV?")

        let executorMessages = mockClient.messageHistory[1]
        let userContent = executorMessages.first(where: { $0["role"] == "user" })?["content"] ?? ""

        #expect(userContent.contains("恢复评分"))
        #expect(userContent.contains("User question: How's my HRV?"))
    }

    @MainActor
    @Test("cost is tracked after each API call")
    func testCostTrackedAfterEachCall() async throws {
        let plannerTokens = makeTokenUsage(prompt: 10, completion: 20)
        let executorTokens = makeTokenUsage(prompt: 30, completion: 40)
        let mockClient = MockDeepSeekClient()
        mockClient.responses = [
            (content: makePlannerJSON(), usage: plannerTokens),
            (content: "Done.", usage: executorTokens),
        ]
        let costTracker = makeCostTracker()
        let viewModel = ChatViewModel(
            deepSeekService: mockClient,
            messageStore: MockMessageStore(),
            costTracker: costTracker
        )

        await viewModel.sendMessage("test")

        let sessionCost = costTracker.sessionCost()
        let expectedCost = costTracker.calculateCost(usage: plannerTokens) + costTracker.calculateCost(usage: executorTokens)
        #expect(abs(sessionCost - expectedCost) < 0.000001)
        #expect(mockClient.callCount == 2)
    }

    @MainActor
    @Test("error message is shown on API failure")
    func testErrorMessageOnAPIFailure() async throws {
        let failingViewModel = ChatViewModel(
            deepSeekService: ThrowingService(),
            messageStore: MockMessageStore(),
            costTracker: makeCostTracker()
        )

        await failingViewModel.sendMessage("This will fail")

        #expect(failingViewModel.errorMessage != nil)
        #expect(failingViewModel.errorMessage?.contains("simulatedFailure") == true)
        #expect(failingViewModel.messages.count >= 2)
    }

    @MainActor
    @Test("messages are persisted to DatabaseService")
    func testChatHistoryPersisted() async throws {
        let mockClient = MockDeepSeekClient()
        mockClient.responses = [
            (content: makePlannerJSON(), usage: makeTokenUsage()),
            (content: "Recovery is on track.", usage: makeTokenUsage()),
        ]
        let messageStore = MockMessageStore()
        let viewModel = ChatViewModel(
            deepSeekService: mockClient,
            messageStore: messageStore,
            costTracker: makeCostTracker()
        )

        await viewModel.sendMessage("How am I doing?")

        #expect(messageStore.savedMessages.count == 2)
        #expect(messageStore.savedMessages[0].role == "user")
        #expect(messageStore.savedMessages[0].content == "How am I doing?")
        #expect(messageStore.savedMessages[1].role == "assistant")
        #expect(messageStore.savedMessages[1].content == "Recovery is on track.")
    }

    @Test("extractJSON returns plain JSON unchanged")
    func testExtractJSONPlain() {
        let result = ChatViewModel._extractJSONForTesting("{\"a\":\"b\"}")
        #expect(result == "{\"a\":\"b\"}")
    }

    @Test("extractJSON removes fenced markdown code block")
    func testExtractJSONFenced() {
        let result = ChatViewModel._extractJSONForTesting("```json\n{\"a\":1}\n```")
        #expect(result == "{\"a\":1}")
    }

    @Test("extractJSON extracts nested braces from prose")
    func testExtractJSONProseNested() {
        let result = ChatViewModel._extractJSONForTesting("here is data: {\"a\":{\"b\":2}} thanks")
        #expect(result == "{\"a\":{\"b\":2}}")
    }

    @Test("extractJSON handles braces inside string values")
    func testExtractJSONBracesInString() {
        let result = ChatViewModel._extractJSONForTesting("{\"note\":\"has } brace in string\"}")
        #expect(result == "{\"note\":\"has } brace in string\"}")
    }

    @MainActor
    @Test("lastTurnCost and sessionCost differ after two turns")
    func testLastTurnVsSessionCostDiffer() async throws {
        let plannerTokens = makeTokenUsage(prompt: 100, completion: 50)
        let executorTokens = makeTokenUsage(prompt: 200, completion: 100)
        let mockClient = MockDeepSeekClient()
        mockClient.responses = [
            (content: makePlannerJSON(), usage: plannerTokens),
            (content: "Turn 1.", usage: executorTokens),
            (content: makePlannerJSON(), usage: plannerTokens),
            (content: "Turn 2.", usage: executorTokens),
        ]
        let costTracker = makeCostTracker()
        let viewModel = ChatViewModel(
            deepSeekService: mockClient,
            messageStore: MockMessageStore(),
            costTracker: costTracker
        )

        await viewModel.sendMessage("turn 1")
        await viewModel.sendMessage("turn 2")

        let lastTurn = viewModel.lastTurnCost
        let session = costTracker.sessionCost()
        #expect(lastTurn > 0)
        #expect(session > lastTurn)
    }

    @Test("manual_activities placeholder is replaced when a value is injected")
    func testManualActivitiesPlaceholderReplacedOnInject() {
        let template = "人工记录：\n{manual_activities}"
        // 修复后 ChatViewModel 总会注入值（数据或"无手动记录"），render 必替换占位符。
        let filled = PromptBuilder.render(template, with: ["manual_activities": "无手动记录"])
        #expect(filled == "人工记录：\n无手动记录")
        #expect(!filled.contains("{manual_activities}"))
    }
}
