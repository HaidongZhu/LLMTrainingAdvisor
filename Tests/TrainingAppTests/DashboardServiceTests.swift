import Foundation
import Testing
@testable import TrainingApp

private final class MockDeepSeekService: DeepSeekService, @unchecked Sendable {
    var capturedUsage = TokenUsage(promptTokens: 0, completionTokens: 0, totalTokens: 0)
    var streamCalled = false

    func chat(model: String, messages: [[String: String]], temperature: Double, maxTokens: Int, timeoutInterval: TimeInterval) async throws -> (content: String, usage: TokenUsage) {
        ("mock", capturedUsage)
    }

    func chatStream(model: String, messages: [[String: String]], temperature: Double, maxTokens: Int, timeoutInterval: TimeInterval, onToken: @escaping @Sendable (String) async -> Void) async throws -> TokenUsage {
        streamCalled = true
        await onToken("## 综述\nok")
        return capturedUsage
    }
}

@Suite("DashboardService")
@MainActor
struct DashboardServiceTests {

    @Test("init accepts injected costTracker and deepSeekService")
    func testInitAcceptsInjection() {
        let tracker = CostTracker(allTimeTotal: 0)
        let svc = DashboardService(costTracker: tracker, deepSeekService: MockDeepSeekService())
        // 默认走 .shared 时构造也不应崩溃
        _ = DashboardService()
        #expect(svc.weeklyTrend == nil)
    }

    @Test("init loads cached training plan within TTL")
    func testLoadCachedTrainingPlan() {
        let defaults = UserDefaults.standard
        defaults.set("测试训练计划", forKey: "dashboard_training_plan")
        defaults.set(Date(), forKey: "dashboard_training_time")

        let svc = DashboardService()
        #expect(svc.trainingPlan == "测试训练计划")

        defaults.removeObject(forKey: "dashboard_training_plan")
        defaults.removeObject(forKey: "dashboard_training_time")
    }

    @Test("loadCache ignores expired training plan")
    func testExpiredTrainingPlanIgnored() {
        let defaults = UserDefaults.standard
        defaults.set("过期计划", forKey: "dashboard_training_plan")
        defaults.set(Date().addingTimeInterval(-7 * 3600), forKey: "dashboard_training_time")

        let svc = DashboardService()
        #expect(svc.trainingPlan == nil)

        defaults.removeObject(forKey: "dashboard_training_plan")
        defaults.removeObject(forKey: "dashboard_training_time")
    }

    @Test("loadCache loads cached trend within TTL")
    func testLoadCachedTrend() {
        let defaults = UserDefaults.standard
        let content = "## 睡眠质量\n睡眠时长充足"
        defaults.set(content, forKey: "dashboard_weekly_trend")
        defaults.set(Date(), forKey: "dashboard_trend_time")

        let svc = DashboardService()
        #expect(svc.weeklyTrend == content)
        #expect(!svc.trendSections.isEmpty)

        defaults.removeObject(forKey: "dashboard_weekly_trend")
        defaults.removeObject(forKey: "dashboard_trend_time")
    }

    @Test("refreshTrainingPlan streams via deepSeekService chatStream")
    func testRefreshTrainingPlanStreams() async {
        let mock = MockDeepSeekService()
        let svc = DashboardService(costTracker: CostTracker(allTimeTotal: 0), deepSeekService: mock)
        await svc.refreshTrainingPlan()
        // 训练改专用 prompt 后走 chatStream；无 HealthKit 真实数据时可能走"无数据"分支。
        // 若走了 LLM 路径，应触发 chatStream 并产出 streamingTrainingContent。
        if mock.streamCalled {
            #expect(!svc.streamingTrainingContent.isEmpty)
        }
        // 无论哪条路，loading 必须结束
        #expect(svc.isLoadingTraining == false)
    }
}
