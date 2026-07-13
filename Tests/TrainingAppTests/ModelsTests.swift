import Foundation
import Testing
@testable import TrainingApp

@Suite("Models")
struct ModelsTests {

    @Test("ChatMessage Codable roundtrip")
    func chatMessageCodableRoundtrip() throws {
        let id = UUID()
        let message = ChatMessage(
            id: id,
            role: "user",
            content: "What's a good workout for today?",
            fullRequest: "System: You are a trainer.\nUser: What's a good workout for today?",
            tokenIn: 42,
            tokenOut: 128,
            cost: 0.0015,
            createdAt: Date(timeIntervalSince1970: 1_750_000_000)
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(message)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ChatMessage.self, from: data)

        #expect(decoded.id == id)
        #expect(decoded.role == "user")
        #expect(decoded.content == "What's a good workout for today?")
        #expect(decoded.fullRequest == "System: You are a trainer.\nUser: What's a good workout for today?")
        #expect(decoded.tokenIn == 42)
        #expect(decoded.tokenOut == 128)
        #expect(decoded.cost == 0.0015)
        #expect(decoded.createdAt == Date(timeIntervalSince1970: 1_750_000_000))
    }

    @Test("PlannerResponse JSON decoding from sample JSON")
    func plannerResponseDecoding() throws {
        let json = """
        {
            "tools": [
                {"call_id": "rec", "name": "get_recovery_score", "params": {}},
                {"call_id": "sum7", "name": "get_daily_summary", "params": {"range": "7"}}
            ],
            "prompt_template": "恢复评分：{rec}\\n每日：{sum7}"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(PlannerResponse.self, from: json)

        #expect(response.tools.count == 2)
        #expect(response.tools[0].name == "get_recovery_score")
        #expect(response.tools[0].callId == "rec")
        #expect(response.tools[1].params["range"] == "7")
        #expect(response.promptTemplate.contains("{rec}"))
    }

    @Test("ActivityLog Codable roundtrip")
    func activityLogCodableRoundtrip() throws {
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

        let encoder = JSONEncoder()
        let data = try encoder.encode(activity)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ActivityLog.self, from: data)

        #expect(decoded.id == id)
        #expect(decoded.date == activityDate)
        #expect(decoded.type == "Soccer")
        #expect(decoded.durationMin == 90.0)
        #expect(decoded.distanceKm == 8.5)
        #expect(decoded.intensity == "high")
        #expect(decoded.notes == "Friendly match at the park")
        #expect(decoded.createdAt == Date(timeIntervalSince1970: 1_750_100_000))
    }

    @Test("ActivityLog optional fields nil roundtrip")
    func activityLogOptionalFieldsNilRoundtrip() throws {
        let activity = ActivityLog(
            id: UUID(),
            date: Date(),
            type: "Running",
            durationMin: nil,
            distanceKm: nil,
            intensity: nil,
            notes: nil,
            createdAt: Date()
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(activity)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ActivityLog.self, from: data)

        #expect(decoded.type == "Running")
        #expect(decoded.durationMin == nil)
        #expect(decoded.distanceKm == nil)
        #expect(decoded.intensity == nil)
        #expect(decoded.notes == nil)
    }

    @Test("TokenUsage JSON decoding from DeepSeek API response format")
    func tokenUsageDecodingFromDeepSeekFormat() throws {
        let json = """
        {
            "prompt_tokens": 42,
            "completion_tokens": 128,
            "total_tokens": 170
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let usage = try decoder.decode(TokenUsage.self, from: json)

        #expect(usage.promptTokens == 42)
        #expect(usage.completionTokens == 128)
        #expect(usage.totalTokens == 170)
    }

    @Test("TokenUsage CodingKeys correctness")
    func tokenUsageCodingKeys() throws {
        let usage = TokenUsage(promptTokens: 10, completionTokens: 20, totalTokens: 30)
        let encoder = JSONEncoder()
        let data = try encoder.encode(usage)

        let jsonString = String(data: data, encoding: .utf8)!
        #expect(jsonString.contains("prompt_tokens"))
        #expect(jsonString.contains("completion_tokens"))
        #expect(jsonString.contains("total_tokens"))
    }

    @Test("UserProfile key-value behavior")
    func userProfileKeyValue() {
        let profile = UserProfile(key: "preferred_name", value: "Alex")
        #expect(profile.key == "preferred_name")
        #expect(profile.value == "Alex")
    }

    @Test("ChatMessage Identifiable conformance")
    func chatMessageIdentifiable() {
        let id = UUID()
        let message = ChatMessage(
            id: id,
            role: "assistant",
            content: "Try a 20-minute HIIT session today.",
            fullRequest: "",
            tokenIn: 0,
            tokenOut: 0,
            cost: 0,
            createdAt: Date()
        )
        #expect(message.id == id)
    }

    @Test("AnyCodable preserves decimal values correctly")
    func testAnyCodableDecimal() throws {
        let testCases: [(String, String)] = [
            ("5.5", "5.5"),
            ("5.0", "5"),
            ("7", "7"),
            ("\"abc\"", "abc"),
        ]
        for (json, expected) in testCases {
            let data = "{\"v\": \(json)}".data(using: .utf8)!
            struct Wrapper: Codable { let v: AnyCodable }
            let decoded = try JSONDecoder().decode(Wrapper.self, from: data)
            #expect(decoded.v.stringValue == expected)
        }
    }
}
