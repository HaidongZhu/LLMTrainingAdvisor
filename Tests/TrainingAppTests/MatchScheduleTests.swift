import Foundation
import Testing
@testable import TrainingApp

@Suite("MatchSchedule")
struct MatchScheduleTests {

    private func makeService() throws -> DatabaseService {
        try DatabaseService(databasePath: ":memory:")
    }

    @Test("insert and query upcoming match")
    func testInsertAndQueryUpcoming() throws {
        let db = try makeService()
        let match = MatchSchedule(
            id: UUID(), date: Date().addingTimeInterval(86400), time: "20:00",
            opponent: nil, intensity: "medium", notes: nil,
            actualDurationMin: nil, actualIntensity: nil, isCompleted: false, createdAt: Date()
        )
        try db.insertMatchSchedule(match)

        let upcoming = try db.queryUpcomingMatches()
        #expect(upcoming.count == 1)
        #expect(upcoming[0].intensity == "medium")
    }

    @Test("completed match moves to past")
    func testCompletedMatchInPast() throws {
        let db = try makeService()
        let match = MatchSchedule(
            id: UUID(), date: Date().addingTimeInterval(-86400), time: "21:00",
            opponent: "老男孩", intensity: "high", notes: nil,
            actualDurationMin: nil, actualIntensity: nil, isCompleted: true, createdAt: Date()
        )
        try db.insertMatchSchedule(match)

        let past = try db.queryPastMatches()
        #expect(past.count == 1)
        #expect(past[0].opponent == "老男孩")
    }

    @Test("update match schedule")
    func testUpdateMatch() throws {
        let db = try makeService()
        let id = UUID()
        var match = MatchSchedule(
            id: id, date: Date().addingTimeInterval(86400), time: "20:00",
            opponent: nil, intensity: "medium", notes: nil,
            actualDurationMin: nil, actualIntensity: nil, isCompleted: false, createdAt: Date()
        )
        try db.insertMatchSchedule(match)

        match.isCompleted = true
        match.actualDurationMin = 90
        try db.updateMatchSchedule(match)

        let past = try db.queryPastMatches()
        #expect(past.count == 1)
        #expect(past[0].actualDurationMin == 90)
    }

    @Test("delete match schedule")
    func testDeleteMatch() throws {
        let db = try makeService()
        let match = MatchSchedule(
            id: UUID(), date: Date().addingTimeInterval(86400), time: "20:00",
            opponent: nil, intensity: "medium", notes: nil,
            actualDurationMin: nil, actualIntensity: nil, isCompleted: false, createdAt: Date()
        )
        try db.insertMatchSchedule(match)
        try db.deleteMatchSchedule(id: match.id)

        let upcoming = try db.queryUpcomingMatches()
        #expect(upcoming.isEmpty)
    }
}
