# 细粒度时段查询 设计（spec）

## 背景

对话模式问"昨天比赛整体表现如何"时，Executor 触发数据缺口闸门：
"无法完整评估表现：缺少比赛中心率、跑动强度分布、加减速符合等关键数据"。

## 诊断结论

模拟 Planner + 分析调用链后定位：

- **Planner 只调了 `get_workout_table(range=2)`，没调 `get_metric` 查心率等**。workout 表只有时长/距离/热量，缺心率/运动负荷。
- **`get_metric` 当前只能按"整天"聚合**（`queryDay` 用 0:00-23:59，`range=N` 按天聚合）。无法查"比赛那 2 小时"或"赛后 1 小时"或"今天 0 点到现在"的细粒度数据。
- Apple Watch workout 记录含 `startDate`/`endDate`，可据此按时段查 HealthKit 样本。
- "跑动强度分布/加减速符合"Apple Watch 无此类样本——属于不可得数据，应说明"不提供"而非"缺失"。

## 用户需求（四类场景）

| 场景 | 粒度 | 现状 |
|------|------|------|
| 比赛/训练表现 | 某场 workout 时段（如 2h）的细粒度心率 | ❌ |
| 赛后恢复 | 赛后 1 小时等任意时段 | ❌ |
| "看今天状态" | 今天 0:00 到现在的细粒度（非整天聚合） | ❌ |
| 过去 7 天趋势 | 按天聚合 | ✅ 已有 |

## 已确认的决策（brainstorming）

1. **今日窗口边界 = 今天 0:00 → now**。不引入"起床"概念。start 用当日 0 点，end 用 `Date()`。
2. **新增独立工具 `get_workout_metrics`**，而非给 `get_metric` 加跨工具引用参数。职责隔离，Planner 也更好理解。
3. **`get_workout_metrics` 内部按 `type` + `date` 自己查 HealthKit 找那场 workout 的时段**，不引用别的工具的输出（无 `workout_ref=call_id` 机制）。理由：用户"按道理会指明具体到哪天、什么运动，应该够了；没有同时分析几天里几场不同比赛的需求"。
4. **序列输出固定 5 分钟桶，不截断、不自适应**。隐含约束：单次时段查询 ≤ 24h（≤ 288 点上限），实际场景（2h 比赛、1h 恢复）远小于此。用户"没道理看超过一天的明细数据"。
5. **心率序列用 `HKStatisticsCollectionQuery` 按 5min 分桶**，每桶取 `discreteMin` + `discreteMax` + `average`，一次查询拿到 min/max/avg 三序列，不逐点拉原始样本。

## 设计

### 1. `get_metric` 扩展：支持任意时段（通用相对窗口）

现有 `get_metric` 支持 `range=N`（按天聚合，含今天）、`days_ago=N`（单日）、`output`（summary/table）。

**新增参数**（与现有 range/days_ago 互斥，按优先级处理）：

- `hours_ago=N`：以"现在"为基准，往前 N 小时作为窗口起点。N 为正整数。
- `duration_hours=M`：窗口持续 M 小时。M 为正数（支持小数，如 0.5=30min）。
- 二者成对使用：`hours_ago=1, duration_hours=1` 表示"最近结束的这 1 小时往前 1 小时"——即"赛后 1 小时恢复"这类场景（当"现在"恰是赛后恢复时段时，也可 `hours_ago=2, duration_hours=1` 指更早的某 1 小时）。
- `output` 对时段查询同样适用：`summary`（该时段聚合：avg/max/min + 时段内总和）/ `table`（逐 5 分钟序列）。
- 时段查询时，单位/格式化沿用现有 `fmt`（metric 包含 heart_rate/rhr/hrv → "N bpm"）。

**优先级**（执行分支顺序）：
1. `days_ago`（单日整天，优先于 range）
2. `hours_ago` + `duration_hours`（任意时段，本次新增）
3. `range`（按天聚合/趋势）

**时段序列实现**：复用 `HKStatisticsCollectionQuery`，`intervalComponents: DateComponents(minute: 5)`，`options: [.discreteMin, .discreteMax, .discreteAverage]`，predicate 用 `predicateForSamples(withStart: windowStart, end: windowEnd)`。逐桶输出 `min/avg/max`。

### 2. 新工具 `get_workout_metrics`

**职责**：按 `type` + `date` 定位某一场 workout，查该 workout 时段内某项指标的细粒度序列 + 时段统计。

**参数**：
- `type`（必填）：运动类型，如 `Soccer`/`Running`。复用 `HealthDataService.workoutActivityType(forName:)`（football/soccer → .soccer，大小写不敏感）。
- `date`（必填）：`yyyy-MM-dd`。工具内部按此日期查当天该类型的 workout。Planner 把"昨天"解析成具体日期再传（沿用 recordPlanner 的约定）。同一天同类型多场 workout 取第一场（按 startDate 升序），当前需求不涉及多场分析。
- `metric`（必填）：指标名。复用 `MetricTool` 的 metrics 字典 key（如 `average_heart_rate`/`steps`/`active_calories` 等）。
- `output`（可选，默认 `summary`）：`summary`（时段统计 avg/max/min）/ `table`（逐 5 分钟序列）。

**执行流程**：
1. 解析 `type` → `HKWorkoutActivityType`，未知 → 返回"无该运动类型的训练记录"。
2. 用 `predicateForWorkouts(with: actType)` + 当日 0:00-23:59 的 `predicateForSamples` 复合谓词，`HKSampleQuery` 取该场 workout。
3. 找不到 → 返回"未找到 {date} 的 {type} 训练记录"。
4. 用 workout 的 `startDate`/`endDate` 作为时段窗口。
5. 用 `HKStatisticsCollectionQuery`（5min 桶，`[.discreteMin, .discreteMax, .discreteAverage]`）查该窗口内指定 `metric` 的样本。
6. `summary`：输出 avg/max/min；`table`：逐 5 分钟一行 `HH:mm-HH:mm: avg/min/max`。

**返回示例（table）**：
```
2026-07-08 Soccer (19:30-21:30) 心率序列:
19:30-19:35: 128/142/155 bpm (avg/min/max)
19:35-19:40: 135/148/162 bpm
...
```
（格式最终由实现确定，但必须含日期、运动类型、时段、每桶的 avg/min/max。）

### 3. "今天 0:00 到现在" 细粒度

**不用新工具**。`get_metric` 加 `hours_ago`+`duration_hours` 后已能覆盖任意相对窗口。但"今天 0 点到现在"是固定语义，直接让 Planner 用 `range=1, output=table` 不行（range 走按天聚合，table 是逐日不是逐 5 分钟）。

**方案**：`get_metric` 增加一个语义参数 `since=today_start`，表示窗口从今天 0:00 到 now。或更简单——让 Planner 直接用 `hours_ago=<到今天0点的整点数>, duration_hours=<到现在的小时数>`。

**决策**：为避免 Planner 算小时数出错，`get_metric` 增加显式参数 `today=true`（布尔字符串），当为 true 时窗口 = 今天 0:00 → now，忽略 range/days_ago/hours_ago。语义清晰，Planner 不用算时间。

### 4. Planner prompt 调整

在 `plannerSystemPrompt()` 工具清单中：

- `get_metric` 文档补充：`hours_ago`/`duration_hours`（任意时段，如赛后 1h 恢复）、`today=true`（今天 0 点到现在细粒度）。说明 `output=table` 对时段/today 返回逐 5 分钟序列。
- 新增 `get_workout_metrics(type, date, metric, output?)` 文档：查某场 workout 时段的指标序列。评估比赛/训练表现时用此工具（而非 get_workout_table + get_metric 整天）。
- 规则补充：评估某场比赛表现 → 先 `get_workout_table` 定位比赛，再 `get_workout_metrics(type=Soccer, date=yyyy-MM-dd, metric=average_heart_rate)`；评估赛后恢复 → `get_metric(metric=rhr, hours_ago=1, duration_hours=1)`；看今天状态 → `get_metric(metric=average_heart_rate, today=true, output=table)`。

### 5. Executor 数据缺口闸门细化

`systemPrompt` 回复原则第 2 条补充，区分两类缺失：

- **可得但未取**（如心率，Planner 漏调）→ "缺少比赛中心率数据（可获取但未查询）"。
- **Apple Watch 不提供**（强度分布/加加速）→ "Apple Watch 不提供跑动强度分布/加减速符合数据，无法评估此项"。

可在 Executor prompt 中列出"Apple Watch 不提供的指标"，让模型对这类不可得数据主动说明而非报缺失。

## 范围

新能力扩展，独立于 2026-07-09-conversation-prompt-fix plan。走本 spec → plan → 实现。

## 涉及文件

- `Training/Training/Tools/MetricTool.swift`：新增 `hours_ago`+`duration_hours` 分支、`today` 分支、5min 序列查询。
- `Training/Training/Tools/TableTools.swift`：新增 `WorkoutMetricsTool`（`get_workout_metrics`）。
- `Training/Training/HealthDataService.swift`：新增 5min 桶序列查询辅助方法（`bucketStatistics(start:end:id:options:)`）。
- `Training/Training/Tools/ToolRegistry.swift`（或等价注册处）：注册新工具。
- `Training/Training/PromptBuilder.swift`：planner 工具清单 + Executor 闸门细化。
- `Tests/TrainingAppTests/`：新增时段查询、workout_metrics 工具测试。

## 未决问题（已全部解决）

1. ~~"今天起床到现在"的"起床"如何确定？~~ → 不引入起床，今日窗口 = 今天 0:00 → now。
2. ~~workout_ref 跨工具引用？~~ → 不做引用，新工具内部按 type+date 自查。
3. ~~逐 5 分钟序列 token 成本？~~ → 固定 5min 桶，单次 ≤ 24h，不截断。
4. ~~心率序列用哪个 API？~~ → `HKStatisticsCollectionQuery` 5min 桶，min/max/avg。
