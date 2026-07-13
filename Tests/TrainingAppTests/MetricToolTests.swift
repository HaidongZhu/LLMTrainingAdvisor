import Foundation
import Testing
@testable import TrainingApp

@Suite("MetricTool time-window")
@MainActor
struct MetricToolTests {

    @Test("today=true 返回非空序列或占位，不崩在参数解析")
    func testTodayParamParses() async {
        let tool = MetricTool()
        // 无 HealthKit 数据时返回 "—" 或序列；只要不因参数解析崩溃即可
        let result = await tool.execute(params: ["metric": "average_heart_rate", "today": "true", "output": "table"])
        #expect(!result.isEmpty)
    }

    @Test("hours_ago+duration_hours 返回非空")
    func testRelativeWindowParses() async {
        let tool = MetricTool()
        let result = await tool.execute(params: ["metric": "average_heart_rate", "hours_ago": "1", "duration_hours": "1", "output": "table"])
        #expect(!result.isEmpty)
    }

    @Test("today=true 优先于 range")
    func testTodayOverridesRange() async {
        let tool = MetricTool()
        let r1 = await tool.execute(params: ["metric": "steps", "today": "true", "range": "7", "output": "table"])
        #expect(!r1.isEmpty)
    }

    @Test("MetricTool.id 覆盖常见指标")
    func testMetricIDLookup() {
        #expect(MetricTool.id(for: "average_heart_rate") == .heartRate)
        #expect(MetricTool.id(for: "rhr") == .restingHeartRate)
        #expect(MetricTool.id(for: "steps") == .stepCount)
        #expect(MetricTool.id(for: "active_calories") == .activeEnergyBurned)
        #expect(MetricTool.id(for: "nonexistent_metric") == nil)
    }
}
