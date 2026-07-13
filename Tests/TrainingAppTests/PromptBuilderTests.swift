import Foundation
import Testing
@testable import TrainingApp

@Suite("PromptBuilder")
@MainActor
struct PromptBuilderTests {

    // MARK: - System Prompt

    @Test("system prompt contains coach role")
    func testSystemPromptContainsRole() {
        let prompt = PromptBuilder.systemPrompt()
        #expect(prompt.contains("私人健康与运动教练"))
    }

    @Test("system prompt supports user profile section")
    func testSystemPromptHasProfileSection() {
        let prompt = PromptBuilder.systemPrompt()
        #expect(prompt.contains("用户画像"))
    }

    @Test("system prompt contains response principles")
    func testSystemPromptContainsPrinciples() {
        let prompt = PromptBuilder.systemPrompt()
        #expect(prompt.contains("不制造焦虑"))
    }

    // MARK: - Planner Prompt

    @Test("planner prompt lists key tools")
    func testPlannerPromptListsMetrics() {
        let prompt = PromptBuilder.plannerSystemPrompt()
        #expect(prompt.contains("get_metric"))
        #expect(prompt.contains("get_sleep_table"))
        #expect(prompt.contains("get_daily_summary"))
    }

    // MARK: - Template Rendering

    @Test("render replaces placeholders with values")
    func testRenderReplacesPlaceholders() {
        let result = PromptBuilder.render("RHR: {rhr} bpm", with: ["rhr": "57"])
        #expect(result == "RHR: 57 bpm")
    }

    @Test("render leaves unknown key as-is")
    func testRenderMissingKeyLeavesPlaceholder() {
        let result = PromptBuilder.render("RHR: {rhr} bpm", with: [:])
        #expect(result == "RHR: {rhr} bpm")
    }

    @Test("render replaces multiple placeholders")
    func testRenderMultiplePlaceholders() {
        let template = "Steps: {steps}, RHR: {rhr}, HRV: {hrv}"
        let result = PromptBuilder.render(
            template,
            with: ["steps": "8500", "rhr": "58", "hrv": "32.5"]
        )
        #expect(result == "Steps: 8500, RHR: 58, HRV: 32.5")
    }

    // MARK: - Data Summary

    @Test("data summary formats table correctly")
    func testDataSummaryFormatsCorrectly() {
        let metrics: [[String: Double]] = [
            ["date": 20260706, "steps": 4485, "rhr": 68, "hrv": 30.8, "exercise_minutes": 13],
        ]
        let result = PromptBuilder.dataSummary(from: metrics)
        let lines = result.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].contains("日期"))
        #expect(lines[1].contains("20260706"))
        #expect(lines[1].contains("4485"))
        #expect(lines[1].contains("68"))
        #expect(lines[1].contains("31"))
        #expect(lines[1].contains("13"))
    }

    @Test("data summary handles empty input")
    func testDataSummaryEmptyInput() {
        let result = PromptBuilder.dataSummary(from: [])
        #expect(result == "无数据")
    }

    @Test("render does not re-substitute values produced by expansion")
    func testRenderDoesNotReSubstitute() {
        let result = PromptBuilder.render("{a}{b}", with: ["a": "{b}", "b": "X"])
        #expect(result == "{b}X")
    }

    @Test("render produces same output across repeated calls")
    func testRenderOrderIndependent() {
        let template = "A: {x}, B: {y}"
        let data = ["x": "1", "y": "2"]
        let r1 = PromptBuilder.render(template, with: data)
        let r2 = PromptBuilder.render(template, with: data)
        #expect(r1 == r2)
        #expect(r1 == "A: 1, B: 2")
    }

    @Test("planner prompt example JSON is valid with unique call_ids")
    func testPlannerExampleJSONIsValid() throws {
        let prompt = PromptBuilder.plannerSystemPrompt()
        guard let range = prompt.range(of: "{") else {
            #expect(Bool(false), "No JSON found in planner prompt")
            return
        }
        let jsonCandidate = ChatViewModel._extractJSONForTesting(String(prompt[range.lowerBound...]))
        let data = try #require(jsonCandidate.data(using: .utf8))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let tools = try #require(obj?["tools"] as? [[String: Any]])
        #expect(tools.count == 6)
        let callIds = Set(tools.compactMap { $0["call_id"] as? String })
        #expect(callIds.count == tools.count, "All call_ids should be unique")
    }

    // MARK: - Task 7: Executor prompt improvements

    @Test("system prompt instructs Chinese replies")
    func testSystemPromptChineseInstruction() {
        #expect(PromptBuilder.systemPrompt().contains("使用简体中文"))
    }

    @Test("system prompt has route guidance distinguishing plan vs analysis")
    func testSystemPromptRouteGuidance() {
        let p = PromptBuilder.systemPrompt()
        #expect(p.contains("路由"))
    }

    @Test("system prompt has data-gap hard gate")
    func testSystemPromptDataGapGate() {
        let p = PromptBuilder.systemPrompt()
        #expect(p.contains("无法分析") || p.contains("数据缺口") || p.contains("关键数据缺失"))
    }

    @Test("system prompt has no-data fallback rule")
    func testSystemPromptNoDataFallback() {
        let p = PromptBuilder.systemPrompt()
        #expect(p.contains("无数据") || p.contains("编造"))
    }

    @Test("training plan format example uses plain text not fenced code block")
    func testTrainingFormatNoFencedBlock() {
        #expect(!PromptBuilder.systemPrompt().contains("```"))
    }

    // MARK: - Task 8: Planner prompt improvements

    @Test("planner prompt says tools should be on-demand, not copy example")
    func testPlannerOnDemandGuidance() {
        let p = PromptBuilder.plannerSystemPrompt()
        #expect(p.contains("按需") || p.contains("不必照搬"))
    }

    @Test("planner prompt documents range includes today")
    func testPlannerRangeSemantics() {
        let p = PromptBuilder.plannerSystemPrompt()
        #expect(p.contains("含今天") || p.contains("包含今天"))
    }

    @Test("planner prompt declares dual data sources for matches")
    func testPlannerDualSource() {
        let p = PromptBuilder.plannerSystemPrompt()
        #expect(p.contains("workout_table") && p.contains("manual_activities") && p.contains("比赛"))
    }

    @Test("planner prompt documents days_ago and type params")
    func testPlannerNewParamsDocs() {
        let p = PromptBuilder.plannerSystemPrompt()
        #expect(p.contains("days_ago"))
        #expect(p.contains("type"))
    }

    // MARK: - Task 9: recordPlanner + weeklyTrend style fixes

    @Test("record planner uses yyyy not YYYY date format")
    func testRecordPlannerDateFormat() {
        let p = PromptBuilder.recordPlannerSystemPrompt()
        #expect(!p.contains("YYYY-MM-DD"))
        #expect(p.contains("yyyy-MM-dd"))
    }

    @Test("record planner handles unknown activity type")
    func testRecordPlannerUnknownTypeGuidance() {
        let p = PromptBuilder.recordPlannerSystemPrompt()
        #expect(p.contains("最接近") || p.contains("notes"))
    }

    @Test("weekly trend prompt marks example dates as non-real")
    func testWeeklyTrendExampleNonReal() {
        let p = PromptBuilder.weeklyTrendPrompt(data: "x")
        #expect(p.contains("示例") && (p.contains("非真实") || p.contains("格式")))
    }

    // MARK: - Time-window query docs

    @Test("planner prompt documents hours_ago and duration_hours")
    func testPlannerTimeWindowParams() {
        let p = PromptBuilder.plannerSystemPrompt()
        #expect(p.contains("hours_ago"))
        #expect(p.contains("duration_hours"))
        #expect(p.contains("today"))
    }

    @Test("planner prompt documents get_workout_metrics tool")
    func testPlannerWorkoutMetricsTool() {
        let p = PromptBuilder.plannerSystemPrompt()
        #expect(p.contains("get_workout_metrics"))
    }

    @Test("executor prompt distinguishes unavailable vs fetchable data")
    func testExecutorGapDistinction() {
        let p = PromptBuilder.systemPrompt()
        #expect(p.contains("不提供"))
    }

    // MARK: - Trend prompt optimization (8-section)

    @Test("weekly trend prompt has 本周概览 before 恢复状态")
    func testTrendOverviewFirst() {
        let p = PromptBuilder.weeklyTrendPrompt(data: "x")
        let overview = p.range(of: "## 本周概览")
        let recovery = p.range(of: "## 恢复状态")
        #expect(overview != nil)
        #expect(recovery != nil)
        #expect(overview!.lowerBound < recovery!.lowerBound)
    }

    @Test("weekly trend prompt has 8 sections")
    func testTrendSectionCount() {
        let p = PromptBuilder.weeklyTrendPrompt(data: "x")
        let sections = p.components(separatedBy: "## ").filter { !$0.isEmpty }
        #expect(sections.count >= 8)
    }

    @Test("weekly trend prompt has conciseness constraint")
    func testTrendConciseness() {
        let p = PromptBuilder.weeklyTrendPrompt(data: "x")
        #expect(p.contains("结论"))
        #expect(p.contains("禁止套话"))
    }

    @Test("weekly trend prompt has new sections")
    func testTrendNewSections() {
        let p = PromptBuilder.weeklyTrendPrompt(data: "x")
        #expect(p.contains("伤病风险预警"))
        #expect(p.contains("下周展望"))
        #expect(p.contains("运动负荷细分"))
    }

    @Test("training plan prompt exists and has format")
    func testTrainingPlanPrompt() {
        let p = PromptBuilder.trainingPlanPrompt(data: "x")
        #expect(p.contains("今天练什么"))
        #expect(p.contains("结论"))
        #expect(p.contains("禁止套话"))
    }

    // MARK: - Prompt caching: system 部分（稳定前缀）不含动态 data

    @Test("weekly trend system prompt includes current timestamp")
    func testTrendSystemStable() {
        let s = PromptBuilder.weeklyTrendSystemPrompt()
        #expect(s.contains("当前时间"))
        #expect(s.contains("本周概览"))
    }

    @Test("training system prompt includes current timestamp")
    func testTrainingSystemStable() {
        let s = PromptBuilder.trainingPlanSystemPrompt()
        #expect(s.contains("当前时间"))
        #expect(s.contains("今天练什么"))
    }
}
