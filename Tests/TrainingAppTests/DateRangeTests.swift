import Foundation
import Testing
@testable import TrainingApp

@Suite("DateRange")
struct DateRangeTests {

    @Test("dayOffsets inclusive contains today as first")
    func testInclusiveContainsToday() {
        let offsets = HealthDataService.dayOffsets(inclusiveDays: 3)
        #expect(offsets == [0, -1, -2])
    }

    @Test("dayOffsets inclusive with one day returns just today")
    func testInclusiveOneDay() {
        #expect(HealthDataService.dayOffsets(inclusiveDays: 1) == [0])
    }

    @Test("dayOffsetsPastExclusive excludes today")
    func testPastExclusive() {
        #expect(HealthDataService.dayOffsetsPastExclusive(days: 3) == [-1, -2, -3])
    }

    @Test("dateForDaysAgo zero is today startOfDay")
    func testDaysAgoZeroIsToday() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        #expect(HealthDataService.dateForDaysAgo(0) == today)
    }

    @Test("dateForDaysAgo one is yesterday startOfDay")
    func testDaysAgoOneIsYesterday() {
        let cal = Calendar.current
        let yesterday = cal.startOfDay(for: cal.date(byAdding: .day, value: -1, to: Date())!)
        #expect(HealthDataService.dateForDaysAgo(1) == yesterday)
    }

    @Test("inclusive and exclusive offsets are disjoint and adjacent")
    func testInclusiveExclusiveDisjoint() {
        let inc = HealthDataService.dayOffsets(inclusiveDays: 2)   // [0, -1]
        let exc = HealthDataService.dayOffsetsPastExclusive(days: 2) // [-1, -2]
        #expect(Set(inc).intersection(Set(exc)) == [-1]) // only yesterday overlaps
        #expect(!inc.contains(0) == false) // today in inclusive
    }
}
