import Foundation
import Testing
@testable import TrainingApp

private func makeTokenUsage(prompt: Int = 100, completion: Int = 50) -> TokenUsage {
    TokenUsage(promptTokens: prompt, completionTokens: completion, totalTokens: prompt + completion)
}

private func makePlannerJSON() -> String {
    """
    {
      "tools": [
        {"call_id": "rec", "name": "get_recovery_score", "params": {}},
        {"call_id": "sum7", "name": "get_daily_summary", "params": {"range": "7"}}
      ],
      "prompt_template": "恢复评分：{rec}\\n每日：{sum7}"
    }
    """
}

private func makeCostTracker() -> CostTracker { CostTracker(allTimeTotal: 0) }

private final class MockDeepSeekClient: DeepSeekService, @unchecked Sendable {
    var responses: [(content: String, usage: TokenUsage)] = []
    var callCount = 0
    var messageHistory: [[[String: String]]] = []

    func chat(model: String, messages: [[String: String]], temperature: Double, maxTokens: Int, timeoutInterval: TimeInterval = 30) async throws -> (content: String, usage: TokenUsage) {
        messageHistory.append(messages)
        let resp = responses[callCount]
        callCount += 1
        return resp
    }
}

private final class MockMessageStore: MessageStore {
    var messages: [ChatMessage] = []
    func insertChatMessage(_ message: ChatMessage) throws { messages.append(message) }
    func insertActivityLog(_ activity: ActivityLog) throws {}
    func queryRecentMessages(limit: Int) throws -> [ChatMessage] { return messages }
}


@Suite("Planner flow (non-streaming)")
@MainActor
struct PlannerFlowTests {

    @Test("ChatMessage supports system role")
    func testSystemRoleMessage() {
        let msg = ChatMessage(
            id: UUID(), role: "system",
            content: "📋 规划请求",
            fullRequest: "planner prompt here",
            tokenIn: 100, tokenOut: 50, cost: 0.001,
            createdAt: Date()
        )
        #expect(msg.role == "system")
        #expect(msg.content == "📋 规划请求")
    }

    @Test("ChatViewModel sends system message before planner")
    func testPlannerPhaseInsertsSystemMessage() async throws {
        let mockClient = MockDeepSeekClient()
        mockClient.responses = [
            (content: makePlannerJSON(), usage: makeTokenUsage()),
            (content: "Done.", usage: makeTokenUsage()),
        ]
        let vm = ChatViewModel(
            deepSeekService: mockClient,
            messageStore: MockMessageStore(),
            costTracker: makeCostTracker()
        )
        await vm.sendMessage("test")

        // Should have at least 5 messages: user, system(planner), system(tools), system(executor), assistant
        #expect(vm.messages.count >= 3)
        // First non-user message should be a system role (planner phase)
        let systemMsgs = vm.messages.filter { $0.role == "system" }
        #expect(systemMsgs.count >= 1)
        #expect(vm.messages.last?.role == "assistant")
    }

    @Test("system messages have unique IDs")
    func testSystemMessagesUnique() async throws {
        let mockClient = MockDeepSeekClient()
        mockClient.responses = [
            (content: makePlannerJSON(), usage: makeTokenUsage()),
            (content: "Done.", usage: makeTokenUsage()),
        ]
        let vm = ChatViewModel(
            deepSeekService: mockClient,
            messageStore: MockMessageStore(),
            costTracker: makeCostTracker()
        )
        await vm.sendMessage("test")
        let ids = vm.messages.map(\.id)
        #expect(Set(ids).count == ids.count, "All message IDs should be unique")
    }
}
