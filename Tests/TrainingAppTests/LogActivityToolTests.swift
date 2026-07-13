import Foundation
import Testing
@testable import TrainingApp

@Suite("Log activity tool")
struct LogActivityToolTests {

    @Test("log_activity tool inserts activity")
    func testLogActivityInserts() async throws {
        let db = try DatabaseService(databasePath: ":memory:")
        let tool = LogActivityTool(store: db)
        let result = await tool.execute(params: [
            "type": "Soccer",
            "date": "2026-07-06",
            "duration_min": "60",
            "intensity": "medium"
        ])
        #expect(result.contains("已记录"))
        let activities = try db.queryAllActivities()
        #expect(activities.count == 1)
        #expect(activities[0].type == "Soccer")
        #expect(activities[0].durationMin == 60)
    }

    @Test("log_activity tool handles minimal params")
    func testLogActivityMinimal() async throws {
        let db = try DatabaseService(databasePath: ":memory:")
        let tool = LogActivityTool(store: db)
        let result = await tool.execute(params: ["type": "Running", "date": "2026-07-06"])
        #expect(result.contains("已记录"))
    }

    @Test("log_activity with distance")
    func testLogActivityWithDistance() async throws {
        let db = try DatabaseService(databasePath: ":memory:")
        let tool = LogActivityTool(store: db)
        await tool.execute(params: ["type": "Running", "date": "2026-07-06", "distance_km": "5.2"])
        let activities = try db.queryAllActivities()
        #expect(activities[0].distanceKm == 5.2)
    }
}
