import Foundation
import Testing
@testable import TrainingApp

@Suite("DashboardService trend dates")
struct DashboardTrendDateTests {

    @Test("trend uses past-exclusive 7 days for its own stat loop")
    func testTrendPastExclusive() {
        // 趋势自有的 dailyStatistics 迭代应为过去 7 天不含今天
        let offsets = HealthDataService.dayOffsetsPastExclusive(days: 7)
        #expect(offsets.count == 7)
        #expect(!offsets.contains(0))  // 不含今天
        #expect(offsets.first == -1)   // 从昨天起
    }
}
