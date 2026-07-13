import Foundation
import Testing
@testable import TrainingApp

@Suite("MetricTool date params")
struct MetricToolDateTests {

    @Test("days_ago present routes to single-day query (no HealthKit returns dash)")
    func testDaysAgoRoutesSingleDay() async {
        let tool = MetricTool()
        // 无 HealthKit 数据时单日查询返回 "—"
        let out = await tool.execute(params: ["metric": "rhr", "days_ago": "1"])
        #expect(out == "—")
    }

    @Test("range=1 summary no longer special-cased to today-only; falls through to aggregate")
    func testRangeOneGoesThroughAggregatePath() async {
        let tool = MetricTool()
        // range=1 走聚合路径（含今天），无 HealthKit 返回 "—"
        let out = await tool.execute(params: ["metric": "rhr", "range": "1"])
        #expect(out == "—")
    }
}
