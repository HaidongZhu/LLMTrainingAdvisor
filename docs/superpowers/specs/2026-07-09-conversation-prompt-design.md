# 对话 Prompt 优化与取数修复 设计

## 背景

对话模式（对话/记录/趋势/训练 Tab）走 LLM 的链路为：
**用户问题 → Planner prompt 决定工具调用 → 工具取数 → Executor prompt 渲染数据并回答**。

实际使用中发现两类问题：

1. **Prompt 质量问题**：示例照搬、无数据兜底缺失、路由判定缺失、`{manual_activities}` 占位符污染 Executor 输入、`YYYY` 格式陷阱等。
2. **取数正确性 bug**：
   - "昨天睡得怎么样" → 拿到前天数据或平均数（range 语义不一致 + 无法表达"昨天"）。
   - "昨天比赛如何" → 说没比赛，但 HealthKit 明明有 football workout（数据源双轨未声明 + 无法按类型/日期定位）。

诊断结论：取数 bug 的根因一半在 **Planner prompt 对 range / 数据源的描述**，另一半在 **工具代码的 range 语义与参数能力**。两者必须一起修，否则模型受限于工具能力，无法准确回答。

## 范围

**本次包含**：PromptBuilder 文字优化、manual_activities 占位符兜底、工具代码 range 语义统一 + 新增 `days_ago`/`type` 参数。

**本次不包含（单独 spec）**：身体数据（伤病/体检/年龄）从硬编码迁移到 `user_profile` 表。

## 成功标准

- "昨天睡得怎么样" → 返回**昨晚**的睡眠数据，而非前天或今天。
- "昨天比赛如何" → 若有昨晚 football workout，能定位并分析；若比赛在手动记录里（没戴手表），也能查到。
- 关键数据缺失时，Executor 在回复第一句声明缺失并终止分析，不强行编造。
- Planner 对简单问题只调必要工具，不照搬 6 工具示例。

---

## §1 代码改动 — manual_activities 占位符兜底

**文件**：`ChatViewModel.swift`（`sendMessage` 中 manual_activities 注入逻辑，约第 330-339 行）。

**当前**：仅当 `manualResult != "无手动记录"` 时注入 `context["manual_activities"]`，无数据时不注入，导致 `{manual_activities}` 占位符以字面量流入 Executor 输入。

**改后**：无论有无数据都注入。有数据注入表格；无数据注入 `"无手动记录"`。保证 `PromptBuilder.render` 一定替换掉 `{manual_activities}` 占位符。

**兜底值选择**：用 `"无手动记录"` 而非空串——空串会让模板中该行变成孤立标题/换行，语义不明；"无手动记录" 对 Executor 是明确信号。

---

## §2 Executor systemPrompt 改动

**文件**：`PromptBuilder.systemPrompt`。

### ① 语言指令
在角色描述后加："所有回复使用简体中文。"

### ② 训练计划格式去掉代码块
当前用 fenced code block（` ``` `）包裹格式模板。改为普通文本 + `例：` 引导。理由：模型看到 fenced block 易连标记原样复述。

```
## 训练计划格式
当用户询问"今天练什么""这周计划""给我一个训练"时，返回结构化计划。格式参考：

例：
今天训练：
- 动作名称 组数×次数（如：死虫式 10×3）
- 组间休息时间
- 负荷建议（如：zone2 心率、自重、弹力带）
训练目的：核心稳定 / 爆发力维持 / 主动恢复
```

### ③ 回复原则补充（原 7 条 → 10 条）

新增三条，其中"数据缺口"为强约束：

1. **路由判定**：用户问训练/计划（"今天练什么""这周计划"）→ 给结构化训练计划；问状态/恢复/睡眠/比赛（"我恢复得怎么样""最近睡眠如何""昨天比赛如何"）→ 给数据分析 + 建议，不套训练计划格式。
2. **数据缺口前置闸门（强约束）**：回复开头先核对——回答用户请求需要哪些数据。若**关键数据缺失**（工具未返回 / 时间范围对不上 / 完全无数据），则**不往下分析**，在第一句告知："⚠️ 无法分析：[缺了什么] — [为什么缺这些就无法回答]"，不要基于无关数据硬凑结论。
   - 例子："我昨天球赛整体表现如何" → 若未获取到昨天那场球赛的详细数据，直接回"⚠️ 无法分析：未获取到昨天球赛的详细数据，无法评估表现"，不基于其他数据编造。
   - 区分：**关键数据**（回答该问题必需）缺失 → 终止；**辅助数据**（锦上添花）缺失 → 可继续分析并注明。关键 vs 辅助的归类由模型判断。
3. **无数据兜底**：若所有健康工具返回无数据，如实告知用户当前无可用数据，不要编造具体数值。
4. **简洁**：回复简洁，围绕用户问题给出可执行结论，避免重复堆砌同义内容。

原"只回答用户问的"从第 1 降为第 2（路由判定更上位）。其余原有原则保留。

---

## §3 Planner systemPrompt 改动

**文件**：`PromptBuilder.plannerSystemPrompt`。

### ① 按需调用 + 最小示例
在现有完整 6 工具示例后加说明与最小示例，防止模型照搬：

> 以上为完整示例，实际工具调用应根据用户问题按需选择。简单问题（如"我昨天睡多久"）只需查询相关工具，不必照搬示例的全部工具。每个工具调用都应有明确用途。
>
> 简单问题示例：用户"我昨天睡多久" → 只调 `get_sleep_table(range=2)`（含今天+昨天），prompt_template 只引用这次结果。

### ② 数据需求优先规划
在规则里加：

> 规划原则：先判断回答用户问题需要哪些数据（今日值？昨日值？趋势？比赛？手动记录？），再据此选择工具和 range。避免冗余调用，也避免漏掉关键数据导致 Executor 无法回答。

### ③ range 语义说明（配合 §4 工具修复）
在工具清单或规则里写死新语义：

> range=N 表示查询**最近 N 天，含今天**。range=1=今天，range=2=今天+昨天。要定位"昨天某项指标"，用 `days_ago=1` 而非 range。

### ④ 数据源双轨声明（对应"昨天比赛"bug）
在工具清单里说明：

> 球赛/比赛记录可能存在两处：戴手表的比赛在 `get_workout_table`（HealthKit）；不允许戴手表的比赛在 `get_manual_activities`（人工登记）。涉及"某场比赛表现"时，两处都要查。

### ⑤ 按类型/单日定位说明
说明新增参数（配合 §4）：

> `get_metric(metric, days_ago?)`：days_ago=N 表示今天往前第 N 天（1=昨天），返回该日单值。
> `get_workout_table(type?, range?)`：type 按运动类型筛选（如 Soccer/Running）。
> `get_manual_activities(type?, range?)`：同上，按类型筛选手动记录。
> 当前工具按 range 查近 N 天，可结合 days_ago/type 精确定位单日或单类记录。

### ⑥ get_user_profile 描述补全（轻量）
写明返回个人静态档案（年龄/伤病/体检），涉及伤病/身体状况判断时可调。**本次不改其硬编码实现**（档案迁移单独 spec）。

---

## §4 工具代码修复（方案 A）

### 核心语义统一
所有工具的 `range=N` 统一表示**最近 N 天，含今天**。

- 当前：`range>1` 用 `cal.date(byAdding: .day, value: -(d+1))` 从昨天起算（不含今天）；`range=1` 走 `querySingle` 查今天。语义不一致。
- 改后：统一从今天起算 `value: -d`（d=0 为今天）。range=1=今天，range=2=今天+昨天。

**涉及工具**：`MetricTool`（summary 与 table 模式）、`SleepTableTool`、`WorkoutTableTool`、`DailySummaryTool`。注意 `HealthDataService.dailyStatistics` 的 days 参数语义也要同步确认。

**趋势场景特殊处理**：`DashboardService.refreshWeeklyTrend` 的 `collectWeeklyData` 当前用 range=7 取"过去 7 天"。统一"含今天"后，趋势会多含今天（今天数据可能不全，影响分析）。处理：DashboardService 在调用工具时显式排除今天——传 range=8 但在结果里跳过今天行，或保留趋势逻辑查 range=7 含昨天起 7 天（即不在通用语义里强行纳入今天，而是给 DashboardService 单独的"过去 N 天不含今天"调用路径）。倾向后者：通用语义含今天，趋势场景用独立参数或方法取"不含今天的过去 N 天"。

### 新增参数 1：days_ago（单日定位）
- 适用于 `get_metric`。
- `get_metric(metric=rhr, days_ago=1)` → 昨天该指标的值（单值）。
- 实现复用 `MetricTool.queryDay(id:opts:date:)`，date = 今天 - days_ago。
- 语义与输出：有 days_ago 时按单日查，返回该日单值（格式同 summary 的单值输出，如 "RHR 62"，不带趋势分析，因为单日无趋势）。无 days_ago 时按 range 聚合（保留 summary 的聚合值+趋势输出）。
- days_ago 与 range 互斥：同时传时 days_ago 优先（按单日）。

### 新增参数 2：type（运动类型筛选）
- 适用于 `get_workout_table` 和 `get_manual_activities`。
- **workout**：建立 type 名称 → `HKWorkoutActivityType` 映射表（如 soccer/football→`.soccer`，running→`.running`，cycling→`.cycling` 等），用 `HKQuery.predicateForWorkouts(with:)` 按类型筛选。
- **manual_activities**：按 `activity_log.type` 字段字符串匹配。
- `get_workout_table(type=Soccer, range=7)` → 最近 7 天（含今天）的足球训练记录。

### 睡眠"昨天"语义
- `SleepTableTool` 的跨夜窗口（3pm-3pm）逻辑保留，统一 range 含今天。
- `get_sleep_table(days_ago=1)` → 昨晚的睡眠（归到昨天）。

### 数据源双轨
`ManualActivitiesTool` 与 `WorkoutTableTool` 保持独立，由 Planner prompt（§3 ④）指引两者都查。无需代码层合并。

---

## §5 风格 / 格式

- **recordPlanner prompt**：`date: YYYY-MM-DD` → `date: yyyy-MM-DD`（避免 week-based year 陷阱）。
- **type 枚举兜底**：recordPlanner 的 type 列表补"未知类型选最接近的并在 notes 注明实际运动"。

---

## 测试策略

- **§1 占位符兜底**：扩展 ChatViewModel 测试，验证无手动记录时 `{manual_activities}` 被替换为"无手动记录"而非字面量流入 Executor。
- **§4 range 语义**：扩展工具测试（MetricTool/SleepTableTool/WorkoutTableTool/DailySummaryTool），验证 range=1 含今天、range=2 含今天+昨天。
- **§4 days_ago**：测试 `get_metric(days_ago=1)` 返回昨天的值。
- **§4 type 筛选**：测试 `get_workout_table(type=Soccer)` 只返回足球记录（mock HealthKit 样本）；`get_manual_activities(type=Soccer)` 同理。
- **§2/§3 prompt**：扩展 PromptBuilderTests，验证新指令存在（语言指令、路由判定、数据缺口闸门、range 语义说明、数据源双轨声明等）。
- 真机验证：手动测"昨天睡得怎么样""昨天比赛如何"两个场景。

## 风险与权衡

- **range 语义变更可能影响现有行为**：趋势 Tab（DashboardService.refreshWeeklyTrend 用 collectWeeklyData，range=7）需确认含义不变（仍取过去 7 天）。统一为"含今天"后，趋势会多含一天今天的数据——需评估是否可接受（今天数据可能不全）。倾向：趋势场景明确排除今天（用 range=8 取过去 7 天，或 DashboardService 显式排除今天）。
- **days_ago/type 是新增参数**：需更新 Planner prompt 教模型使用，否则模型不会主动用。
- **workout type 映射表维护**：需覆盖常见运动，未映射的 type 按最近似处理。
