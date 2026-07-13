import Foundation
import Testing
@testable import TrainingApp

@Suite("Record mode")
@MainActor
struct RecordModeTests {

    @Test("ActivityLog CRUD: insert, query, delete")
    func testCRUD() throws {
        let db = try DatabaseService(databasePath: ":memory:")
        let log = ActivityLog(id: UUID(), date: Date(), type: "Running", durationMin: 30, distanceKm: 5.0, intensity: "medium", notes: nil, createdAt: Date())
        try db.insertActivityLog(log)
        let all = try db.queryAllActivities()
        #expect(all.count == 1)
        #expect(all[0].type == "Running")
        try db.deleteActivity(id: log.id)
        #expect(try db.queryAllActivities().isEmpty)
    }

    @Test("ActivityLog update")
    func testUpdate() throws {
        let db = try DatabaseService(databasePath: ":memory:")
        let log = ActivityLog(id: UUID(), date: Date(), type: "Soccer", durationMin: 60, distanceKm: nil, intensity: "high", notes: nil, createdAt: Date())
        try db.insertActivityLog(log)
        var updated = log
        updated.intensity = "medium"
        try db.updateActivity(updated)
        let all = try db.queryAllActivities()
        #expect(all[0].intensity == "medium")
    }

    @Test("Record mode toggle changes UI state")
    func testModeToggle() {
        let vm = ChatViewModel()
        #expect(vm.selectedTab == 0)
        vm.selectedTab = 3
        #expect(vm.selectedTab == 3)
    }
}
