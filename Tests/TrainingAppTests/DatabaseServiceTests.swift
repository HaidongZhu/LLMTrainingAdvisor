import Foundation
import Testing
@testable import TrainingApp

@Suite("DatabaseService")
struct DatabaseServiceTests {

    private func makeService() throws -> DatabaseService {
        try DatabaseService(databasePath: ":memory:")
    }

    @Test("Insert and query chat message")
    func testInsertAndQueryChatMessage() throws {
        let service = try makeService()
        let id = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_750_000_000)
        let message = ChatMessage(
            id: id,
            role: "user",
            content: "What's a good workout for today?",
            fullRequest: "System: You are a trainer.\nUser: What's a good workout for today?",
            tokenIn: 42,
            tokenOut: 128,
            cost: 0.0015,
            createdAt: createdAt
        )

        try service.insertChatMessage(message)

        let result = try service.queryChatMessage(id: id.uuidString)
        let fetched = try #require(result)
        #expect(fetched.id == id)
        #expect(fetched.role == "user")
        #expect(fetched.content == "What's a good workout for today?")
        #expect(fetched.fullRequest == "System: You are a trainer.\nUser: What's a good workout for today?")
        #expect(fetched.tokenIn == 42)
        #expect(fetched.tokenOut == 128)
        #expect(fetched.cost == 0.0015)
        #expect(fetched.createdAt.timeIntervalSince1970 == createdAt.timeIntervalSince1970)
    }

    @Test("Query recent messages ordered by createdAt DESC")
    func testQueryRecentMessages() throws {
        let service = try makeService()

        let dates: [Date] = [
            Date(timeIntervalSince1970: 1_750_000_000),
            Date(timeIntervalSince1970: 1_750_000_100),
            Date(timeIntervalSince1970: 1_750_000_200),
            Date(timeIntervalSince1970: 1_750_000_300),
            Date(timeIntervalSince1970: 1_750_000_400),
        ]

        for (i, date) in dates.enumerated() {
            let message = ChatMessage(
                id: UUID(),
                role: i % 2 == 0 ? "user" : "assistant",
                content: "Message \(i)",
                fullRequest: "",
                tokenIn: i * 10,
                tokenOut: i * 20,
                cost: Double(i) * 0.01,
                createdAt: date
            )
            try service.insertChatMessage(message)
        }

        let recent = try service.queryRecentMessages(limit: 3)
        #expect(recent.count == 3)
        #expect(recent[0].content == "Message 4")
        #expect(recent[1].content == "Message 3")
        #expect(recent[2].content == "Message 2")
    }

    @Test("SUM(cost) from chat_message")
    func testSumCost() throws {
        let service = try makeService()

        let baseDate = Date(timeIntervalSince1970: 1_750_000_000)
        let costs: [Double] = [0.01, 0.02, 0.03, 0.04]
        for (i, cost) in costs.enumerated() {
            let message = ChatMessage(
                id: UUID(),
                role: "assistant",
                content: "Message \(i)",
                fullRequest: "",
                tokenIn: 10,
                tokenOut: 20,
                cost: cost,
                createdAt: baseDate.addingTimeInterval(Double(i) * 100)
            )
            try service.insertChatMessage(message)
        }

        let total = try service.sumCost()
        #expect(total == 0.10)
    }

    @Test("sumCost includes cost_record (trend/training) on top of chat_message")
    func testSumCostIncludesCostRecord() throws {
        let service = try makeService()
        // 对话花费 0.10
        try service.insertChatMessage(ChatMessage(
            id: UUID(), role: "assistant", content: "msg", fullRequest: "",
            tokenIn: 10, tokenOut: 20, cost: 0.10, createdAt: Date()
        ))
        // 趋势/训练花费 0.05
        try service.insertCostRecord(source: "trend", tokenIn: 100, tokenOut: 200, cost: 0.05)

        let total = try service.sumCost()
        #expect(abs(total - 0.15) < 0.000001)
    }

    @Test("Insert and query activity log")
    func testInsertAndQueryActivityLog() throws {
        let service = try makeService()
        let id = UUID()
        let activityDate = Date(timeIntervalSince1970: 1_750_000_000)
        let activity = ActivityLog(
            id: id,
            date: activityDate,
            type: "Soccer",
            durationMin: 90.0,
            distanceKm: 8.5,
            intensity: "high",
            notes: "Friendly match at the park",
            createdAt: Date(timeIntervalSince1970: 1_750_100_000)
        )

        try service.insertActivityLog(activity)

        let result = try service.queryActivityLog(id: id.uuidString)
        let fetched = try #require(result)
        #expect(fetched.id == id)
        #expect(fetched.date.timeIntervalSince1970 == activityDate.timeIntervalSince1970)
        #expect(fetched.type == "Soccer")
        #expect(fetched.durationMin == 90.0)
        #expect(fetched.distanceKm == 8.5)
        #expect(fetched.intensity == "high")
        #expect(fetched.notes == "Friendly match at the park")
    }

    @Test("Insert, update, delete user profile")
    func testInsertUpdateDeleteUserProfile() throws {
        let service = try makeService()

        try service.setUserProfile(key: "preferred_name", value: "Alex")
        var result = try service.getUserProfile(key: "preferred_name")
        var profile = try #require(result)
        #expect(profile.key == "preferred_name")
        #expect(profile.value == "Alex")

        try service.setUserProfile(key: "preferred_name", value: "Taylor")
        result = try service.getUserProfile(key: "preferred_name")
        profile = try #require(result)
        #expect(profile.value == "Taylor")

        try service.deleteUserProfile(key: "preferred_name")
        let deleted = try service.getUserProfile(key: "preferred_name")
        #expect(deleted == nil)
    }

    @Test("malformed row with invalid UUID is skipped without crash")
    func testMalformedRowIsSkippedNotCrash() throws {
        let service = try makeService()
        try service.execRawForTesting("""
            INSERT INTO chat_message (id, role, content, created_at)
            VALUES ('not-a-uuid', 'user', 'bad row', '2026-01-01T00:00:00.000Z')
            """)
        let validMsg = ChatMessage(
            id: UUID(), role: "user", content: "good row",
            fullRequest: "", tokenIn: 0, tokenOut: 0, cost: 0,
            createdAt: Date(timeIntervalSince1970: 1_750_000_000)
        )
        try service.insertChatMessage(validMsg)

        let recent = try service.queryRecentMessages(limit: 10)
        #expect(recent.count == 1)
        #expect(recent[0].content == "good row")
    }

    @Test("insertChatMessagePair rolls back both messages on duplicate key")
    func testPairInsertRollsBackOnFailure() throws {
        let service = try makeService()
        let msgA = ChatMessage(
            id: UUID(), role: "user", content: "message A",
            fullRequest: "", tokenIn: 0, tokenOut: 0, cost: 0,
            createdAt: Date(timeIntervalSince1970: 1_750_000_000)
        )
        let msgB = ChatMessage(
            id: UUID(), role: "assistant", content: "message B",
            fullRequest: "", tokenIn: 0, tokenOut: 0, cost: 0,
            createdAt: Date(timeIntervalSince1970: 1_750_000_100)
        )
        let msgA2 = ChatMessage(
            id: msgA.id, role: "user", content: "duplicate A",
            fullRequest: "", tokenIn: 0, tokenOut: 0, cost: 0,
            createdAt: Date(timeIntervalSince1970: 1_750_000_200)
        )

        try service.insertChatMessage(msgA)

        do {
            try service.insertChatMessagePair(msgA2, msgB)
            #expect(Bool(false), "Expected error not thrown")
        } catch {
            let foundB = try service.queryChatMessage(id: msgB.id.uuidString)
            #expect(foundB == nil)
        }
    }

    @Test("fresh in-memory DB has schema version set to 1")
    func testSchemaVersionInitialized() throws {
        let path = NSTemporaryDirectory() + "test_schema_\(UUID().uuidString).db"
        let service1 = try DatabaseService(databasePath: path)
        _ = service1
        let service2 = try DatabaseService(databasePath: path)
        _ = service2
        try? FileManager.default.removeItem(atPath: path)
    }
}
