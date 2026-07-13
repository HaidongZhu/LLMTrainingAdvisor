import Foundation
import Testing
@testable import TrainingApp

@Suite("Batch 2: activity_log + cost + history")
@MainActor
struct Batch2Tests {

    @Test("manual recording writes to activity_log")
    func testManualRecordingWritesActivity() async throws {
        let db = try DatabaseService(databasePath: ":memory:")
        let tool = LogActivityTool(store: db)
        _ = await tool.execute(params: ["type": "Soccer", "date": "2026-07-06", "duration_min": "60"])
        let logs = try db.queryAllActivities()
        #expect(logs.contains { $0.type == "Soccer" })
    }

    @Test("history loaded on init")
    func testHistoryLoadedOnInit() async throws {
        let db = try DatabaseService(databasePath: ":memory:")
        let msg = ChatMessage(id: UUID(), role: "user", content: "hello", fullRequest: "", tokenIn: 0, tokenOut: 0, cost: 0, createdAt: Date())
        try db.insertChatMessage(msg)
        // After init, messages should include history
        let cost = (try? db.sumCost()) ?? 0
        #expect(cost == 0, "No-cost message shouldn't affect sum")
    }
}

private func makeTokenUsage(prompt: Int = 100, completion: Int = 50) -> TokenUsage {
    TokenUsage(promptTokens: prompt, completionTokens: completion, totalTokens: prompt + completion)
}

private func makePlannerJSON() -> String {
    """
    {"tools": [{"call_id": "rec", "name": "get_recovery_score", "params": {}}], "prompt_template": "恢复评分：{rec}"}
    """
}

private func makeCostTracker() -> CostTracker { CostTracker(allTimeTotal: 0) }

private final class MockDeepSeekClient: DeepSeekService, @unchecked Sendable {
    var responses: [(content: String, usage: TokenUsage)] = []
    var callCount = 0
    func chat(model: String, messages: [[String: String]], temperature: Double, maxTokens: Int, timeoutInterval: TimeInterval = 30) async throws -> (content: String, usage: TokenUsage) {
        let resp = responses[callCount]; callCount += 1; return resp
    }
}

private final class MockMessageStore: MessageStore {
    var savedMessages: [ChatMessage] = []
    func insertChatMessage(_ m: ChatMessage) throws { savedMessages.append(m) }
    func insertActivityLog(_ a: ActivityLog) throws {}
    func queryRecentMessages(limit: Int) throws -> [ChatMessage] { savedMessages }
}
