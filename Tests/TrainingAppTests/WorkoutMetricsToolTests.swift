import Foundation
import Testing
import HealthKit
@testable import TrainingApp

@Suite("WorkoutMetricsTool")
@MainActor
struct WorkoutMetricsToolTests {

    @Test("缺少必要参数返回提示")
    func testMissingParams() async {
        let tool = WorkoutMetricsTool()
        let r = await tool.execute(params: ["type": "Soccer"])
        #expect(r.contains("缺少必要参数"))
    }

    @Test("日期格式错误返回提示")
    func testBadDateFormat() async {
        let tool = WorkoutMetricsTool()
        let r = await tool.execute(params: ["type": "Soccer", "date": "07-08", "metric": "average_heart_rate"])
        #expect(r.contains("日期格式错误"))
    }

    @Test("未知运动类型返回 nil 映射（HealthDataService 层）")
    func testUnknownTypeMapping() {
        #expect(HealthDataService.workoutActivityType(forName: "Basketball") == nil)
        #expect(HealthDataService.workoutActivityType(forName: "soccer") == .soccer)
        #expect(HealthDataService.workoutActivityType(forName: "Football") == .soccer)
    }

    @Test("metricID 复用 MetricTool.id 覆盖常见指标")
    func testMetricIDCoverage() {
        #expect(MetricTool.id(for: "average_heart_rate") == .heartRate)
        #expect(MetricTool.id(for: "rhr") == .restingHeartRate)
        #expect(MetricTool.id(for: "steps") == .stepCount)
        #expect(MetricTool.id(for: "active_calories") == .activeEnergyBurned)
        #expect(MetricTool.id(for: "nonexistent_metric") == nil)
    }
}
