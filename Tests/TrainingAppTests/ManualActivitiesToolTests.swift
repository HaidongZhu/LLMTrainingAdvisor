import Foundation
import Testing
@testable import TrainingApp

@Suite("ManualActivitiesTool")
struct ManualActivitiesToolTests {

    @Test("reads activities from activity_log table")
    func testManualActivitiesReadsActivityLog() async throws {
        let db = try DatabaseService(databasePath: ":memory:")
        let activity = ActivityLog(
            id: UUID(), date: Date(), type: "Soccer",
            durationMin: 90.0, distanceKm: nil, intensity: nil,
            notes: nil, createdAt: Date()
        )
        try db.insertActivityLog(activity)

        let tool = ManualActivitiesTool(store: db)
        let output = await tool.execute(params: [:])

        #expect(output.contains("Soccer"))
    }

    @Test("type filter returns only matching activities")
    func testTypeFilterMatchesOnlySoccer() async throws {
        let db = try DatabaseService(databasePath: ":memory:")
        try db.insertActivityLog(ActivityLog(
            id: UUID(), date: Date(), type: "Soccer",
            durationMin: 90.0, distanceKm: nil, intensity: nil,
            notes: nil, createdAt: Date()))
        try db.insertActivityLog(ActivityLog(
            id: UUID(), date: Date(), type: "Running",
            durationMin: 30.0, distanceKm: nil, intensity: nil,
            notes: nil, createdAt: Date()))

        let tool = ManualActivitiesTool(store: db)
        let output = await tool.execute(params: ["type": "soccer"])

        #expect(output.contains("Soccer"))
        #expect(!output.contains("Running"))
    }

    @Test("workoutActivityType maps soccer names")
    func testWorkoutTypeMapping() {
        #expect(HealthDataService.workoutActivityType(forName: "Soccer") == .soccer)
        #expect(HealthDataService.workoutActivityType(forName: "soccer") == .soccer)
        #expect(HealthDataService.workoutActivityType(forName: "football") == .soccer)
        #expect(HealthDataService.workoutActivityType(forName: "Running") == .running)
        #expect(HealthDataService.workoutActivityType(forName: "unknown-sport") == nil)
    }
}
