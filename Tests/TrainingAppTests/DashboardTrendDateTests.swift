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

    @Test("trend inclusive 7 days contains today as first")
    func testTrendInclusive7Days() {
        // DashboardService 趋势表循环已改为 inclusive，含今天
        let offsets = HealthDataService.dayOffsets(inclusiveDays: 7)
        #expect(offsets.count == 7)
        #expect(offsets.first == 0)  // 含今天
        #expect(offsets.last == -6)  // 到 6 天前
    }
}
// 验证边界标注：
// 趋势表"今天 HRV 与对话路径 get_metric(hrv,range=1) 一致"依赖
// 真机 HealthKit 实际采样，单测无法覆盖，属"依赖真实跑起来后才能定"。
