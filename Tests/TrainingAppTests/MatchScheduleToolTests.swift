import Foundation
import Testing
@testable import TrainingApp

@Suite("MatchScheduleTool")
struct MatchScheduleToolTests {

    @Test("returns formatted match table when matches exist")
    func testReturnsFormattedTable() async throws {
        let db = try DatabaseService(databasePath: ":memory:")
        let match = MatchSchedule(
            id: UUID(), date: Date().addingTimeInterval(86400 * 3),
            time: "20:00", opponent: "老男孩", intensity: "high",
            notes: nil, actualDurationMin: nil, actualIntensity: nil,
            isCompleted: false, createdAt: Date()
        )
        try db.insertMatchSchedule(match)

        let tool = MatchScheduleTool(store: db)
        let output = await tool.execute(params: [:])

        #expect(output.contains("老男孩"))
        #expect(output.contains("high") || output.contains("高强度"))
        #expect(!output.contains("无未来比赛"))
    }

    @Test("returns 无未来比赛 when no upcoming matches")
    func testReturnsEmptyWhenNoMatches() async throws {
        let db = try DatabaseService(databasePath: ":memory:")
        let tool = MatchScheduleTool(store: db)
        let output = await tool.execute(params: [:])

        #expect(output.contains("无未来比赛"))
    }
}
