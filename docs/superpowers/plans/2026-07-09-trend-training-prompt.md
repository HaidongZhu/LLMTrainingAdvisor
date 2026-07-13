# 趋势与训练 prompt 优化 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 趋势 Tab 重写 prompt（8段结构+简洁约束+今天细粒度+比赛日程+闸门）；训练 Tab 去掉 Planner，改专用 prompt + 固定取数 + 一次流式 LLM。

**Architecture:** 趋势沿用固定取数模式但改造 collectWeeklyData（今天细粒度+比赛日程）；训练从 ChatViewModel 两步链路改为 DashboardService 内直接 collectTrainingData → chatStream 流式。两者复用 MetricTool.queryWindow（today=true）。

**Tech Stack:** Swift 6 / SwiftUI @Observable / HealthKit / DeepSeek chatStream / Swift Testing

## Global Constraints

- 今天细粒度统一走 `MetricTool.queryWindow`（today=true 路径），不另写查询。
- 训练 Tab 保留流式输出（chatStream + onToken）。
- 计费继续累计 `CostTracker.shared`（沿用 accumulateCost / onCostChanged）。
- prompt 段落标题固定 `## ` 开头（趋势靠 parseSections 按 `## ` 分段渲染）。
- 趋势温度 0.3，训练温度 0.3（沿用现状）。
- 训练 Tab 取数复用现有工具：MetricTool（today）、SleepTableTool（range=2 取昨晚+今晚）、WorkoutTableTool（range=3）、ManualActivitiesTool（range=3）、MatchScheduleTool 或 DB queryUpcomingMatches。
- 不改对话 Tab 的 planner/executor prompt（本次范围外）。
- 测试用 Swift Testing。

---

## 文件结构

- `Training/Training/PromptBuilder.swift`（修改）：weeklyTrendPrompt 重写 + trainingPlanPrompt 新增。
- `Training/Training/DashboardService.swift`（修改）：collectWeeklyData 改造 + collectTrainingData 新增 + refreshTrainingPlan 改造。
- `Training/Training/Tools/MetricTool.swift`（无改，复用 queryWindow；若需暴露 helper 再说）。
- `Tests/TrainingAppTests/PromptBuilderTests.swift`（修改）：补趋势新结构 + 训练 prompt 断言。
- `Tests/TrainingAppTests/DashboardServiceTests.swift`（修改）：refreshTrainingPlan 不再依赖 ChatViewModel 的断言需更新。

---

### Task 1: weeklyTrendPrompt 重写

**Files:**
- Modify: `Training/Training/PromptBuilder.swift`

**Interfaces:**
- Produces: `PromptBuilder.weeklyTrendPrompt(data:)` 新结构（8段）

- [ ] **Step 1: 重写 weeklyTrendPrompt**

替换 `weeklyTrendPrompt(data:)` 整个函数体为：

```swift
static func weeklyTrendPrompt(data: String) -> String {
    """
    你是健康数据分析师。根据以下过去 7 天的详尽数据，按指定结构分析。

    ## 输出要求（严格遵守）
    - 每段开头一句结论，后跟 2-3 句数据支撑，禁止套话、禁止重复堆同义内容。
    - 关键数据缺失时在概览说明，不编造数值。
    - 今天的数据用细粒度（统计+逐5分钟序列）解释当天波动，不要把全天当预估。
    - 段落标题必须用 `## ` 开头，顺序固定如下，段间空行分隔。

    ## 本周概览
    1 句话总结本周状态 + 本周应关注什么（点出最该注意的 1-2 件事，如"恢复负债未还"/"某项风险升高"）。

    ## 恢复状态
    综合 RHR/HRV/睡眠，结论先行：本周恢复处于什么水平。

    ## 睡眠质量
    时长/深睡/REM 趋势，结合运动负荷解释变化。

    ## RHR 趋势
    静息心率变化趋势，结合运动负荷解释波动（含今天细粒度异常点）。

    ## HRV 趋势
    心率变异性变化趋势，结合运动负荷解释波动。

    ## 运动负荷细分
    把训练和活动记录按"比赛/训练/日常活动"归类，看负荷来源，不只看总分钟。

    ## 伤病风险预警
    结合恢复不足/负荷突增/旧伤（内收肌/足底/膝），判断本周哪项风险升高。

    ## 下周展望
    根据本周趋势 + 未来比赛日程，给下周训练强度调整建议。

    数据如下（含前6天聚合 + 今天细粒度 + 未来比赛，以下示例格式非真实数据）：

    \(data)
    """
}
```

- [ ] **Step 2: 编译验证**

Run: `cd Training && swift build`
Expected: 编译通过。

- [ ] **Step 3: Commit**

```bash
git add Training/Training/PromptBuilder.swift
git commit -m "feat: rewrite weeklyTrendPrompt with 8-section structure + conciseness"
```

---

### Task 2: trainingPlanPrompt 新增

**Files:**
- Modify: `Training/Training/PromptBuilder.swift`

**Interfaces:**
- Produces: `PromptBuilder.trainingPlanPrompt(data:)` 新方法

- [ ] **Step 1: 新增 trainingPlanPrompt**

在 `weeklyTrendPrompt` 之后新增：

```swift
static func trainingPlanPrompt(data: String) -> String {
    """
    你是私人健康与运动教练。用户是 {age} 岁业余足球运动员（后腰/边后卫），每周三和周末比赛。
    训练目标：长期维持竞技状态、预防伤病，安全第一。

    ## 伤病历史
    - {injury_history}
    - {injury_history}
    - {injury_history}

    ## 比赛节奏
    周三 + 周末比赛。赛前两天不做力竭训练。

    ## 任务
    根据以下数据，给出"今天练什么"的训练计划。

    ## 输出要求（严格遵守）
    - 第一句结论：今天主练什么 + 为什么（结合恢复状态/距下一场比赛天数）。
    - 然后给动作清单，每项：动作名称 组数×次数 / 组间休息 / 负荷建议 / 训练目的。
    - 结论先行、动作清单紧凑、禁止套话、禁止重复。
    - 恢复数据缺失时说明，不编造数值。
    - 结合伤病调整：内收肌避免大幅侧向移动；足底避免赤足跳跃跑跳。

    数据如下（今日恢复状态 + 未来比赛 + 近几天负荷）：

    \(data)
    """
}
```

- [ ] **Step 2: 编译验证**

Run: `cd Training && swift build`
Expected: 编译通过。

- [ ] **Step 3: Commit**

```bash
git add Training/Training/PromptBuilder.swift
git commit -m "feat: add trainingPlanPrompt for dedicated training tab flow"
```

---

### Task 3: collectWeeklyData 改造（今天细粒度 + 比赛日程）

**Files:**
- Modify: `Training/Training/DashboardService.swift`

**Interfaces:**
- Consumes: `MetricTool`（today=true）、`HealthDataService.bucketStatistics`、`MatchScheduleTool` 或 DB queryUpcomingMatches
- Produces: collectWeeklyData 返回含今天细粒度 + 比赛日程的字符串

- [ ] **Step 1: collectWeeklyData 加今天细粒度**

在 collectWeeklyData 末尾（return blocks.joined 之前）插入今天细粒度采集。对 RHR 和 HRV 各调 MetricTool(today=true, output=table)，并补一个统计块。

先看 collectWeeklyData 现状：它用 `dayOffsetsPastExclusive(days: 7)` 即前7天不含今天。所以"前6天"需改成 `dayOffsetsPastExclusive(days: 6)`，今天单独走细粒度。

修改 metricKeys 循环的 days：
```swift
for offset in HealthDataService.dayOffsetsPastExclusive(days: 6) {  // 前6天，不含今天
```

然后在循环之后、sleep/workout/manual 之前，加今天细粒度：

```swift
// 今天细粒度（0点到现在）：RHR/HRV 的统计 + 逐5分钟序列
let metricTool = MetricTool()
let todayRhrTable = await metricTool.execute(params: ["metric": "rhr", "today": "true", "output": "table"])
let todayHrvTable = await metricTool.execute(params: ["metric": "hrv", "today": "true", "output": "table"])
let todayRhrSummary = await metricTool.execute(params: ["metric": "rhr", "today": "true", "output": "summary"])
let todayHrvSummary = await metricTool.execute(params: ["metric": "hrv", "today": "true", "output": "summary"])
var todayBlock: [String] = ["=== 今天 (\(shortDate(Date()))) 细粒度 ==="]
if todayRhrSummary != "—" { todayBlock.append("RHR 统计: \(todayRhrSummary)") }
if todayRhrTable != "—" { todayBlock.append("RHR 逐5分钟:\n\(todayRhrTable)") }
if todayHrvSummary != "—" { todayBlock.append("HRV 统计: \(todayHrvSummary)") }
if todayHrvTable != "—" { todayBlock.append("HRV 逐5分钟:\n\(todayHrvTable)") }
if todayBlock.count > 1 { blocks.append(todayBlock.joined(separator: "\n")) }
```

- [ ] **Step 2: collectWeeklyData 加比赛日程**

在 todayBlock 之后加：

```swift
// 未来比赛日程（供下周展望）
if let db = try? DatabaseService(databasePath: nil) {
    // 用 live DB
} 
let upcoming = (try? DatabaseService.live.queryUpcomingMatches(limit: 3)) ?? []
if !upcoming.isEmpty {
    let rows = upcoming.map { m in "\(shortDate(m.date)) \(m.time) \(m.opponent ?? "") (\(m.intensity ?? ""))" }
    blocks.append("=== 未来比赛 ===\n" + rows.joined(separator: "\n"))
}
```

注：`DatabaseService.live` 是现有单例，直接用。queryUpcomingMatches 已有。若返回 MatchSchedule 的字段名不同，以实际为准（实现时核对 MatchSchedule 模型）。

- [ ] **Step 3: 编译验证**

Run: `cd Training && swift build`
Expected: 编译通过。

- [ ] **Step 4: Commit**

```bash
git add Training/Training/DashboardService.swift
git commit -m "feat: collectWeeklyData adds today fine-grained + upcoming matches"
```

---

### Task 4: collectTrainingData 新增 + refreshTrainingPlan 改造

**Files:**
- Modify: `Training/Training/DashboardService.swift`

**Interfaces:**
- Consumes: MetricTool(today)、SleepTableTool、WorkoutTableTool、ManualActivitiesTool、DatabaseService.live、trainingPlanPrompt、deepSeekService.chatStream
- Produces: collectTrainingData、refreshTrainingPlan（去 Planner 流式版）

- [ ] **Step 1: 新增 collectTrainingData**

在 collectWeeklyData 之后新增：

```swift
private func collectTrainingData() async -> String {
    var blocks: [String] = []
    let metricTool = MetricTool()

    // 今日恢复状态（今天0点到现在）
    let rhr = await metricTool.execute(params: ["metric": "rhr", "today": "true", "output": "summary"])
    let hrv = await metricTool.execute(params: ["metric": "hrv", "today": "true", "output": "summary"])
    var recovery: [String] = ["=== 今日恢复状态 ==="]
    if rhr != "—" { recovery.append("今日 RHR: \(rhr)") }
    if hrv != "—" { recovery.append("今日 HRV: \(hrv)") }

    // 昨晚睡眠
    let sleepTool = SleepTableTool()
    let sleep = await sleepTool.execute(params: ["range": "2"])
    if sleep.hasPrefix("|") { recovery.append("睡眠:\n\(sleep)") }
    if recovery.count > 1 { blocks.append(recovery.joined(separator: "\n")) }

    // 未来比赛日程
    let upcoming = (try? DatabaseService.live.queryUpcomingMatches(limit: 3)) ?? []
    if !upcoming.isEmpty {
        let rows = upcoming.map { m in "\(shortDate(m.date)) \(m.time) \(m.opponent ?? "") (\(m.intensity ?? ""))" }
        blocks.append("=== 未来比赛 ===\n" + rows.joined(separator: "\n"))
    }

    // 近几天负荷（过去3天）
    let workoutTool = WorkoutTableTool()
    let workout = await workoutTool.execute(params: ["range": "3"])
    if workout.hasPrefix("|") { blocks.append("=== 近几天负荷 ===\n\(workout)") }
    let manualTool = ManualActivitiesTool(store: DatabaseService.live)
    let manual = await manualTool.execute(params: ["range": "3"])
    if manual.hasPrefix("|"), !manual.contains("无手动记录") { blocks.append("人工记录:\n\(manual)") }

    return blocks.joined(separator: "\n\n")
}
```

- [ ] **Step 2: refreshTrainingPlan 改造（去 Planner，专用 prompt + 流式）**

替换 `refreshTrainingPlan` 整个函数为：

```swift
func refreshTrainingPlan() async {
    guard !isLoadingTraining else { return }
    isLoadingTraining = true
    trainingError = nil
    trainingPlan = nil
    streamingTrendContent = ""  // 复用流式缓冲（训练也流式）

    let data = await collectTrainingData()
    guard !data.isEmpty else {
        trainingError = "无数据"
        isLoadingTraining = false
        trainingPlan = defaults.string(forKey: trainingCacheKey)
        return
    }

    do {
        let usage = try await deepSeekService.chatStream(
            model: AppConfig.deepSeekModel,
            messages: [["role": "user", "content": PromptBuilder.trainingPlanPrompt(data: data)]],
            temperature: 0.3,
            maxTokens: 4000,
            timeoutInterval: 120,
            onToken: { @MainActor token in
                self.streamingTrendContent += token
            }
        )
        accumulateCost(usage: usage)

        let content = streamingTrendContent
        guard !content.isEmpty else {
            trainingError = "未获取到回复"
            isLoadingTraining = false
            trainingPlan = defaults.string(forKey: trainingCacheKey)
            return
        }
        trainingPlan = content
        trainingUpdatedAt = Date()
        defaults.set(content, forKey: trainingCacheKey)
        defaults.set(Date(), forKey: trainingTimeKey)
    } catch {
        trainingError = error.localizedDescription
        trainingPlan = defaults.string(forKey: trainingCacheKey)
    }
    isLoadingTraining = false
}
```

注：复用 `streamingTrendContent` 作训练流式缓冲，避免新增状态字段（趋势/训练不同时跑，互不干扰）。如倾向分离，可新增 `streamingTrainingContent`——但需同步改 UI 绑定，本次先用复用版。

- [ ] **Step 3: 移除不再需要的 makeViewModel / trainingChatVM（如无其他引用）**

检查 `trainingChatVM` 是否在 UI 层（WeeklyTrendView/TrainingPlanView）被引用。若被引用流式显示，需保留或替换。实现时先 grep 确认。

Run: `grep -rn "trainingChatVM\|makeViewModel" Training/`
若 UI 不再依赖，删除 makeViewModel（但训练不再用它）。若 UI 用 trainingChatVM 做流式显示，需改 UI 绑定 streamingTrendContent。

- [ ] **Step 4: 编译验证**

Run: `cd Training && swift build`
Expected: 编译通过。

- [ ] **Step 5: Commit**

```bash
git add Training/Training/DashboardService.swift Training/Training/*.swift
git commit -m "feat: training tab drops Planner, uses dedicated prompt + streaming"
```

---

### Task 5: 测试 — PromptBuilder 趋势 + 训练断言

**Files:**
- Modify: `Tests/TrainingAppTests/PromptBuilderTests.swift`

- [ ] **Step 1: 补趋势新结构断言**

在 PromptBuilderTests 末尾新增：

```swift
    // MARK: - Trend prompt optimization

    @Test("weekly trend prompt has 本周概览 as first section")
    func testTrendOverviewFirst() {
        let p = PromptBuilder.weeklyTrendPrompt(data: "x")
        let firstSection = p.components(separatedBy: "## ").dropFirst().first ?? ""
        #expect(firstSection.hasPrefix("本周概览"))
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
        #expect(p.contains("结论") || p.contains("禁止套话"))
    }

    @Test("weekly trend prompt has 伤病风险预警 section")
    func testTrendInjuryRisk() {
        let p = PromptBuilder.weeklyTrendPrompt(data: "x")
        #expect(p.contains("伤病风险预警"))
    }

    @Test("training plan prompt exists and has format")
    func testTrainingPlanPrompt() {
        let p = PromptBuilder.trainingPlanPrompt(data: "x")
        #expect(p.contains("今天练什么"))
        #expect(p.contains("内收肌"))
        #expect(p.contains("结论"))
    }
```

- [ ] **Step 2: 运行测试**

Run: `cd Training && swift test --filter PromptBuilderTests`
Expected: PASS（含原有 + 5 新）。

- [ ] **Step 3: Commit**

```bash
git add Tests/TrainingAppTests/PromptBuilderTests.swift
git commit -m "test: trend 8-section + training prompt assertions"
```

---

### Task 6: DashboardServiceTests 更新

**Files:**
- Modify: `Tests/TrainingAppTests/DashboardServiceTests.swift`

- [ ] **Step 1: 检查现有 DashboardServiceTests 对 refreshTrainingPlan 的断言**

Run: `grep -n "refreshTrainingPlan\|trainingPlan\|makeViewModel\|sendMessage" Tests/TrainingAppTests/DashboardServiceTests.swift`

若测试断言 refreshTrainingPlan 调用 ChatViewModel.sendMessage 或 mock deepSeekService 被调2次（planner+executor），需更新为：训练现在1次 chatStream 调用。

- [ ] **Step 2: 更新断言**

把"2次调用"改为"1次 chatStream 调用"，把 systemPrompt 断言改为 trainingPlanPrompt。以实际测试内容为准修改。

- [ ] **Step 3: 运行测试**

Run: `cd Training && swift test --filter DashboardServiceTests`
Expected: PASS。

- [ ] **Step 4: Commit**

```bash
git add Tests/TrainingAppTests/DashboardServiceTests.swift
git commit -m "test: update DashboardServiceTests for Planner-less training flow"
```

---

### Task 7: 全量构建 + 测试

**Files:** 无（验证）

- [ ] **Step 1: 全量构建**

Run: `cd Training && swift build`
Expected: 编译通过。

- [ ] **Step 2: 全量测试**

Run: `cd Training && swift test`
Expected: 全部 PASS。

- [ ] **Step 3: 修复后回到 Step 2 直到全过**

- [ ] **Step 4: Commit（如有修复）**

```bash
git add -A && git commit -m "fix: resolve test failures from trend/training refactor"
```

---

### Task 8: 真机自测验证（趋势 + 训练）

**Files:** 无（验证）

- [ ] **Step 1: build + install**

Run: `cd Training && bash dev_flow.sh build && bash dev_flow.sh install`
Expected: BUILD SUCCEEDED / App installed。

- [ ] **Step 2: 触发趋势刷新并拉日志**

趋势不走 selftest（它不是对话场景）。改用：在 App 里手动进趋势 Tab 触发刷新，或临时加 selftest 场景调 dashboard.refreshWeeklyTrend。本次先用 selftest 场景方式。

若加 selftest 场景成本高，改为：装好 App 后我在 ContentView 趋势 Tab 自动刷新逻辑已存在（autoRefreshDashboard），但 selftest 模式下 ContentView 不渲染。所以趋势验证需另开路径。

**决策：本次用真实对话场景验证训练/趋势 prompt 文本（Task 1-6 已断言），真机端到端验证由用户最后做。趋势/训练 Tab 的 selftest 触发留作后续。**

- [ ] **Step 3: 至少验证训练 prompt 文本已进二进制**

Run: `grep -c "今天练什么" Training/Training/PromptBuilder.swift`
Expected: 计数 ≥1。

- [ ] **Step 4: 交付用户真机验证趋势/训练 Tab 刷新**
