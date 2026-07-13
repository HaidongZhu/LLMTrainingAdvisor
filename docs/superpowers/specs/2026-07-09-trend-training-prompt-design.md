# 趋势与训练 prompt 优化 设计（spec）

## 背景

对话/记录 Tab 的 prompt 已优化（路由/数据缺口闸门/时段查询）。趋势 Tab 和训练 Tab 的 prompt 仍偏旧：趋势回答啰嗦、段落结构不贴合用户关注点、运动负荷只有总分钟、缺未来比赛日程、今天数据用全天聚合而非此刻为止的细粒度。本 spec 优化这两个 Tab。

## 现状

- **趋势**（`DashboardService.refreshWeeklyTrend`）：不走 Planner，`collectWeeklyData` 硬编码收 7 天 daily 聚合（RHR/HRV/步数/运动分钟/睡眠/workout/人工记录）→ 塞 `weeklyTrendPrompt(data:)` 一次 LLM 流式输出，温度 0.3，按 6 段（睡眠/RHR/HRV/运动负荷/恢复/综述）输出。
- **训练**（`refreshTrainingPlan`）：调临时 ChatViewModel 发"今天练什么"，走完整 Planner→工具→Executor 链路，复用对话的 `plannerSystemPrompt` + `systemPrompt`。

## 已确认决策（brainstorming）

1. **两者都改，按优先级先趋势后训练。**
2. **趋势段落结构调整**：恢复状态提前；加伤病风险预警段；加下周展望段；运动负荷细分（比赛/训练/日常）；综述提到最上面并告知"应关注什么"。
3. **简洁约束**：结论先行 + 硬字数上限。每段开头一句结论，后 2-3 句数据支撑；综述严格 1 句 + 应关注点；禁套话、禁重复堆同义内容。
4. **数据缺口闸门**：关键数据缺失（如某天 RHR/HRV 全空）在概览说明，不编造数值。与对话 Executor 一致。
5. **今天细粒度**：趋势里"今天"用细粒度而非全天聚合——今天 0 点到现在的统计（avg/min/max）+ 逐 5 分钟序列都给 LLM；前几天用 daily 聚合。复用 `get_metric` 的 `today=true` 时段查询（queryWindow）。
6. **补查未来比赛日程**：collectWeeklyData 调比赛日程工具，供下周展望段按比赛日调整强度。

## 设计

### 趋势数据层（collectWeeklyData 改造）

当前：7 天 daily 聚合（含今天）。

改为：
- **前 6 天**：daily 聚合（沿用 `dailyStatistics` + `dayOffsetsPastExclusive`）。
- **今天**：对 RHR/HRV 各调一次时段查询，拿到①统计（avg/min/max）②逐 5 分钟序列。用 `MetricTool.queryWindow`（today=true 路径）或直接复用 `HealthDataService.bucketStatistics`（start=今天0点, end=now, bucketMinutes=5）。
- **补比赛日程**：调 `MatchScheduleTool` 或直接查 DB `queryUpcomingMatches(limit:)`，拼成"未来比赛"块。
- 步数/运动分钟/睡眠/workout/人工记录沿用现状（daily）。

数据块格式示例：
```
=== 前6天 daily ===
日期 | RHR
07-08 | 57
...
日期 | HRV
...
=== 今天 (07-09) 细粒度 ===
RHR 统计: avg 61 / min 55 / max 68
RHR 逐5分钟: 09:00 | 58 | 55 | 60
09:05 | 60 | 58 | 62
...
HRV 统计: avg 45 / min 38 / max 52
HRV 逐5分钟: ...
=== 未来比赛 ===
07-12 周六 20:00 vs 老男孩 (high)
07-16 周三 20:00 vs ...
```

### 趋势 prompt（weeklyTrendPrompt 改造）

新结构（8 段，顺序固定，`## ` 标题）：

1. `## 本周概览` — 1 句总结本周状态 + **应关注什么**（点出本周最该注意的 1-2 件事，如"恢复负债未还"/"某项风险升高"）。
2. `## 恢复状态` — 综合 RHR/HRV/睡眠，结论先行：本周恢复处于什么水平。
3. `## 睡眠质量` — 时长/深睡/REM 趋势 + 运动负荷解释。
4. `## RHR 趋势` — 波动 + 运动负荷解释（含今天细粒度异常点）。
5. `## HRV 趋势` — 波动 + 运动负荷解释。
6. `## 运动负荷细分` — 把 workout + 人工记录按"比赛/训练/日常活动"归类，看负荷来源，不只看总分钟。
7. `## 伤病风险预警` — 结合恢复不足/负荷突增/旧伤（内收肌/足底/膝），判断本周哪项风险升高。
8. `## 下周展望` — 根据本周趋势 + 未来比赛日程，给下周训练强度调整建议。

约束（写进 prompt）：
- 每段开头一句结论，后 2-3 句数据支撑，禁套话、禁重复堆同义内容。
- 本周概览严格 1 句结论 + 应关注点。
- 数据缺口闸门：关键数据缺失在概览说明，不编造数值。
- 今天的数据用细粒度（统计+序列）解释当天波动，不要把全天当预估。
- 示例标注非真实数据（沿用现状）。

### 训练 Tab 优化

**核心改动：去掉 Planner，改专用 prompt + 固定取数，一次 LLM 调用出计划。**

理由：训练场景固定就是"今天练什么"，不需要 Planner 动态决策取数。固定收齐三项数据 → 一次 chatStream 流式出计划，省一次 API 往返，响应更快。与趋势 Tab 同模式（固定取数 + 一次 LLM）。

**固定取数（collectTrainingData）**：
- 今日恢复状态：RHR/HRV（今天 0 点到现在，today=true 路径）+ 昨晚睡眠。
- 未来比赛日程：调 MatchScheduleTool / 查 DB `queryUpcomingMatches`，定位下一场球。
- 近几天负荷：过去 3 天 workout + 人工记录，看疲劳累积。

**专用 prompt（trainingPlanPrompt(data:)，新增）**：
- system 含教练角色/伤病/比赛节奏（复用 systemPrompt 的相关段）。
- 数据塞 user content。
- 输出格式：结论先行（今天主练什么 + 为什么，1 句）→ 动作清单（动作 组数×次数 / 组间休息 / 负荷建议 / 训练目的）。
- 简洁约束：结论先行、动作清单紧凑、禁套话、禁重复。
- 保留流式输出（chatStream）。
- 数据缺口闸门：恢复数据缺失时说明，不编造。

**DashboardService.refreshTrainingPlan 改造**：
- 不再调临时 ChatViewModel.sendMessage。
- 改为 collectTrainingData → deepSeekService.chatStream(messages: [system, user], temperature: 0.3, onToken: 流式)。
- 计费仍累计 costTracker（沿用 accumulateCost）。

## 范围

- `PromptBuilder.weeklyTrendPrompt` 改造（结构 + 约束 + 闸门）。
- `PromptBuilder.trainingPlanPrompt(data:)` 新增。
- `DashboardService.collectWeeklyData` 改造（今天细粒度 + 比赛日程）。
- `DashboardService.collectTrainingData` 新增 + `refreshTrainingPlan` 改造（去 Planner，专用 prompt + 流式）。
- `Training/Training/Tools/MetricTool.swift`：queryWindow 已支持 today=true（无需改，复用）。
- 测试：PromptBuilderTests 补趋势新结构 + 训练 prompt 断言；新增 selftest 场景验证（可选）。

## 涉及文件

- `Training/Training/PromptBuilder.swift`：weeklyTrendPrompt 重写 + trainingPlanPrompt 新增。
- `Training/Training/DashboardService.swift`：collectWeeklyData 改造 + collectTrainingData 新增 + refreshTrainingPlan 改造。
- 测试：`Tests/TrainingAppTests/PromptBuilderTests.swift` 补断言。
