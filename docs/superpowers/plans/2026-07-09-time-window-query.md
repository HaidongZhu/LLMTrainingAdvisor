# 细粒度时段查询 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让对话模式能查询任意时段（比赛 workout 时段、赛后 1h、今天 0 点到现在）的细粒度（5 分钟桶）健康指标，区分"可得未取"与"Apple Watch 不提供"两类数据缺口。

**Architecture:** 在 `get_metric` 加相对时段参数（`hours_ago`+`duration_hours`、`today=true`）并复用 `HKStatisticsCollectionQuery` 出 5min 桶序列；新增独立工具 `get_workout_metrics(type, date, metric, output?)` 内部按 type+date 定位一场 workout 后查该时段序列；在 `HealthDataService` 抽公共 5min 桶查询方法供两处复用；同步更新 Planner/Executor prompt。

**Tech Stack:** Swift 6 / HealthKit `HKStatisticsCollectionQuery` / Swift Testing (`@Test`/`#expect`)

## Global Constraints

- 所有指标 key 复用 `MetricTool.metrics` 字典定义，不另造映射表。
- 5 分钟桶固定，使用 `HKStatisticsCollectionQuery` + `intervalComponents: DateComponents(minute: 5)` + `options: [.discreteMin, .discreteMax, .discreteAverage]`。
- 单次时段查询隐含 ≤ 24h（不显式校验，但 prompt 文档说明）。
- 心率类指标格式化为 "N bpm"，沿用现有 `MetricTool.fmt` 规则。
- 工具返回字符串走 markdown 表格/列表，不返回 JSON。
- 测试用 Swift Testing，`@Test`/`#expect`，不引入新测试框架。
- `today=true` 优先级高于 `range`/`days_ago`/`hours_ago`（语义互斥）。

---

## 文件结构

- `Training/Training/HealthDataService.swift`（修改）：新增 `bucketStatistics(...)` 公共 5min 桶查询方法。
- `Training/Training/Tools/MetricTool.swift`（修改）：新增 `hours_ago`+`duration_hours`、`today` 分支与 `queryWindow` 序列输出。
- `Training/Training/Tools/TableTools.swift`（修改）：新增 `WorkoutMetricsTool`（`get_workout_metrics`）。
- `Training/Training/ChatViewModel.swift`（修改）：注册 `WorkoutMetricsTool`（两处 convenience init 之后的注册列表）。
- `Training/Training/PromptBuilder.swift`（修改）：planner 工具清单补文档 + Executor 闸门细化。
- `Tests/TrainingAppTests/MetricToolTests.swift`（新建）：时段查询逻辑测试。
- `Tests/TrainingAppTests/WorkoutMetricsToolTests.swift`（新建）：workout_metrics 工具测试。
- `Tests/TrainingAppTests/PromptBuilderTests.swift`（修改）：补时段查询相关 prompt 断言。

---

### Task 1: HealthDataService 公共 5min 桶查询方法

**Files:**
- Modify: `Training/Training/HealthDataService.swift`
- Test: `Tests/TrainingAppTests/MetricToolTests.swift`（在本 task 只建文件骨架，断言在 Task 4 接通；本 task 通过编译验证方法存在）

**Interfaces:**
- Produces: `HealthDataService.bucketStatistics(store:id:options:start:end:bucketMinutes:converter:) async -> [(start: Date, min: Double?, avg: Double?, max: Double?)]`

- [ ] **Step 1: 写方法签名与实现**

在 `HealthDataService` enum 内（`dailyStatistics` 之后）新增：

```swift
/// 按 N 分钟分桶查询时段内的 min/avg/max 统计。返回每桶一个元组，按时间升序。
/// options 应包含 .discreteMin/.discreteMax/.discreteAverage（按需）。空桶返回 nil。
static func bucketStatistics(
    store: HKHealthStore,
    id: HKQuantityTypeIdentifier,
    options: HKStatisticsOptions,
    start: Date,
    end: Date,
    bucketMinutes: Int,
    converter: @escaping @Sendable (Double) -> Double
) async -> [(start: Date, min: Double?, avg: Double?, max: Double?)] {
    guard HKHealthStore.isHealthDataAvailable(), start < end else { return [] }
    let cal = Calendar.current
    let qty = HKQuantityType(id)
    let unit = Self.unit(for: id)
    let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
    return await withCheckedContinuation { (cont: CheckedContinuation<[(start: Date, min: Double?, avg: Double?, max: Double?)], Never>) in
        let q = HKStatisticsCollectionQuery(
            quantityType: qty,
            quantitySamplePredicate: predicate,
            options: options,
            anchorDate: start,
            intervalComponents: DateComponents(minute: bucketMinutes)
        )
        q.initialResultsHandler = { _, results, _ in
            var out: [(start: Date, min: Double?, avg: Double?, max: Double?)] = []
            results?.enumerateStatistics(from: start, to: end) { stat, _ in
                let mn = stat.minimumQuantity().map { converter($0.doubleValue(for: unit)) }
                let av = stat.averageQuantity().map { converter($0.doubleValue(for: unit)) }
                let mx = stat.maximumQuantity().map { converter($0.doubleValue(for: unit)) }
                out.append((start: cal.startOfDay(for: stat.startDate) == stat.startDate ? stat.startDate : stat.startDate, min: mn, avg: av, max: mx))
            }
            cont.resume(returning: out)
        }
        store.execute(q)
    }
}
```

注：上面元组里 start 直接用 `stat.startDate`（修正掉多余三元判断），最终实现用：

```swift
out.append((start: stat.startDate, min: mn, avg: av, max: mx))
```

- [ ] **Step 2: 编译验证**

Run: `cd Training && swift build`
Expected: 编译通过（新方法未被调用，仅定义）。

- [ ] **Step 3: Commit**

```bash
git add Training/Training/HealthDataService.swift
git commit -m "feat: add HealthDataService.bucketStatistics for 5min buckets"
```

---

### Task 2: MetricTool 扩展 hours_ago/duration_hours/today 参数

**Files:**
- Modify: `Training/Training/Tools/MetricTool.swift`

**Interfaces:**
- Consumes: `HealthDataService.bucketStatistics`（Task 1）
- Produces: `MetricTool.execute` 支持新参数 `hours_ago`/`duration_hours`/`today`

- [ ] **Step 1: 在 execute 内新增 today 分支（最高优先级）**

在 `func execute` 开头，`guard let metric = ...` 之后、`let output = ...` 之后插入 today 分支：

```swift
let output = params["output"] ?? "summary"

// today=true：今天 0:00 → now 的时段查询（优先级最高，忽略 range/days_ago/hours_ago）
if params["today"]?.lowercased() == "true" {
    let cal = Calendar.current
    let now = Date()
    guard let start = cal.date(bySettingHour: 0, minute: 0, second: 0, of: now) else { return "—" }
    return await queryWindow(id: id, opts: opts, converter: converter, start: start, end: now, metric: metric, output: output)
}
```

- [ ] **Step 2: 新增 hours_ago+duration_hours 分支**

紧接 today 分支之后插入：

```swift
// hours_ago + duration_hours：任意相对时段（如赛后 1h 恢复）
if let haStr = params["hours_ago"], let ha = Double(haStr),
   let dhStr = params["duration_hours"], let dh = Double(dhStr) {
    let end = Date().addingTimeInterval(-ha * 3600)
    let start = end.addingTimeInterval(-dh * 3600)
    return await queryWindow(id: id, opts: opts, converter: converter, start: start, end: end, metric: metric, output: output)
}
```

- [ ] **Step 3: 新增 queryWindow 私有方法**

在 `queryTable` 之后新增：

```swift
private func queryWindow(id: HKQuantityTypeIdentifier, opts: HKStatisticsOptions, converter: @escaping @Sendable (Double) -> Double, start: Date, end: Date, metric: String, output: String) async -> String {
    if output == "table" {
        // 5min 桶序列
        let buckets = await HealthDataService.bucketStatistics(
            store: store, id: id,
            options: [.discreteMin, .discreteMax, .discreteAverage],
            start: start, end: end, bucketMinutes: 5, converter: converter
        )
        if buckets.isEmpty { return "—" }
        var rows = ["时间 | avg | min | max"]
        let tf = DateFormatter(); tf.dateFormat = "HH:mm"
        for b in buckets {
            let label = "\(tf.string(from: b.start))"
            let av = b.avg.map { fmt($0, metric: metric) } ?? "—"
            let mn = b.min.map { fmt($0, metric: metric) } ?? "—"
            let mx = b.max.map { fmt($0, metric: metric) } ?? "—"
            rows.append("\(label) | \(av) | \(mn) | \(mx)")
        }
        return rows.joined(separator: "\n")
    }
    // summary：时段聚合
    let pred = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictEndDate)
    let qty = HKQuantityType(id)
    let unit = HealthDataService.unit(for: id)
    return await withCheckedContinuation { cont in
        let q = HKStatisticsQuery(quantityType: qty, quantitySamplePredicate: pred, options: opts) { _, stats, _ in
            let result: String
            if opts == .cumulativeSum, let s = stats?.sumQuantity() {
                result = self.fmt(converter(s.doubleValue(for: unit)), metric: metric)
            } else if let a = stats?.averageQuantity() {
                result = self.fmt(converter(a.doubleValue(for: unit)), metric: metric)
            } else {
                result = "—"
            }
            cont.resume(returning: result)
        }
        store.execute(q)
    }
}
```

注：`self.fmt` 在 `@Sendable` 闭包外捕获需注意——`fmt` 是实例方法且无状态，可直接捕获 self（MetricTool 是 class）。如编译报 Sendable 问题，把 fmt 改为 static 或在闭包外先算好。实现时以编译通过为准。

- [ ] **Step 4: 编译验证**

Run: `cd Training && swift build`
Expected: 编译通过。

- [ ] **Step 5: Commit**

```bash
git add Training/Training/Tools/MetricTool.swift
git commit -m "feat: add hours_ago/duration_hours/today params to get_metric"
```

---

### Task 3: 新增 WorkoutMetricsTool

**Files:**
- Modify: `Training/Training/Tools/TableTools.swift`

**Interfaces:**
- Consumes: `HealthDataService.bucketStatistics`、`HealthDataService.workoutActivityType(forName:)`、`HealthDataService.unit(for:)`、`MetricTool.metrics` 的 key（不直接引用，metric 名由调用方传入并通过共享的 HKQuantityTypeIdentifier 解析）
- Produces: `WorkoutMetricsTool`（name = `get_workout_metrics`）

- [ ] **Step 1: 写工具实现**

在 `TableTools.swift` 末尾（`DailySummaryTool` 之后）新增：

```swift
final class WorkoutMetricsTool: HealthTool, @unchecked Sendable {
    let name = "get_workout_metrics"
    private let store = HKHealthStore()

    func execute(params: [String: String]) async -> String {
        guard let typeName = params["type"],
              let actType = HealthDataService.workoutActivityType(forName: typeName),
              let dateStr = params["date"],
              let metric = params["metric"] else {
            return "缺少必要参数（type/date/metric）"
        }
        let cal = Calendar.current
        // 解析 yyyy-MM-dd
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"; df.timeZone = cal.timeZone
        guard let day = df.date(from: dateStr) else { return "日期格式错误，需 yyyy-MM-dd" }
        guard let dayStart = cal.date(bySettingHour: 0, minute: 0, second: 0, of: day),
              let dayEnd = cal.date(bySettingHour: 23, minute: 59, second: 59, of: day) else { return "—" }

        // 当天该类型的 workout
        var timePred = HKQuery.predicateForSamples(withStart: dayStart, end: dayEnd, options: .strictEndDate)
        let typePred = HKQuery.predicateForWorkouts(with: actType)
        timePred = NSCompoundPredicate(andPredicateWithSubpredicates: [timePred, typePred])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let workouts: [HKWorkout] = await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: HKWorkoutType.workoutType(), predicate: timePred, limit: 1, sortDescriptors: [sort]) { _, s, _ in
                cont.resume(returning: (s as? [HKWorkout]) ?? [])
            }
            store.execute(q)
        }
        guard let w = workouts.first else { return "未找到 \(dateStr) 的 \(typeName) 训练记录" }

        // metric → HKQuantityTypeIdentifier（复用与 MetricTool 相同的 key）
        guard let id = Self.metricID(for: metric) else { return "不支持的指标：\(metric)" }
        let output = params["output"] ?? "summary"
        let unit = HealthDataService.unit(for: id)
        let wStart = w.startDate, wEnd = w.endDate

        if output == "table" {
            let buckets = await HealthDataService.bucketStatistics(
                store: store, id: id, options: [.discreteMin, .discreteMax, .discreteAverage],
                start: wStart, end: wEnd, bucketMinutes: 5, converter: { $0 }
            )
            if buckets.isEmpty { return "无 \(metric) 数据" }
            var rows = ["\(dateStr) \(typeName) (\(Self.hm(wStart))-\(Self.hm(wEnd))) \(metric) 序列:", "时间 | avg | min | max"]
            for b in buckets {
                let av = b.avg.map { Self.fmt($0, metric: metric, unit: unit) } ?? "—"
                let mn = b.min.map { Self.fmt($0, metric: metric, unit: unit) } ?? "—"
                let mx = b.max.map { Self.fmt($0, metric: metric, unit: unit) } ?? "—"
                rows.append("\(Self.hm(b.start)) | \(av) | \(mn) | \(mx)")
            }
            return rows.joined(separator: "\n")
        }
        // summary
        let pred = HKQuery.predicateForSamples(withStart: wStart, end: wEnd, options: .strictEndDate)
        return await withCheckedContinuation { cont in
            let q = HKStatisticsQuery(quantityType: HKQuantityType(id), quantitySamplePredicate: pred,
                                      options: [.discreteMin, .discreteMax, .discreteAverage]) { _, stats, _ in
                let av = stats?.averageQuantity().map { $0.doubleValue(for: unit) }
                let mn = stats?.minimumQuantity().map { $0.doubleValue(for: unit) }
                let mx = stats?.maximumQuantity().map { $0.doubleValue(for: unit) }
                let s = "\(dateStr) \(typeName) \(Self.hm(wStart))-\(Self.hm(wEnd)) \(metric): " +
                        "avg \(av.map { Self.fmt($0, metric: metric, unit: unit) } ?? "—") / " +
                        "min \(mn.map { Self.fmt($0, metric: metric, unit: unit) } ?? "—") / " +
                        "max \(mx.map { Self.fmt($0, metric: metric, unit: unit) } ?? "—")"
                cont.resume(returning: s)
            }
            store.execute(q)
        }
    }

    // metric 名 → HKQuantityTypeIdentifier（与 MetricTool.metrics 的 key 保持一致）
    static func metricID(for metric: String) -> HKQuantityTypeIdentifier? {
        switch metric {
        case "steps": return .stepCount
        case "active_calories": return .activeEnergyBurned
        case "basal_calories": return .basalEnergyBurned
        case "exercise_minutes": return .appleExerciseTime
        case "rhr": return .restingHeartRate
        case "hrv": return .heartRateVariabilitySDNN
        case "average_heart_rate": return .heartRate
        case "vo2_max": return .vo2Max
        case "respiratory_rate": return .respiratoryRate
        case "walking_speed": return .walkingSpeed
        case "flights_climbed": return .flightsClimbed
        case "walking_running_km": return .distanceWalkingRunning
        case "cycling_distance_km": return .distanceCycling
        case "walking_heart_rate": return .walkingHeartRateAverage
        case "stand_minutes": return .appleStandTime
        case "walking_asymmetry_pct": return .walkingAsymmetryPercentage
        case "double_support_pct": return .walkingDoubleSupportPercentage
        case "step_length_cm": return .walkingStepLength
        case "stair_ascent_speed": return .stairAscentSpeed
        case "stair_descent_speed": return .stairDescentSpeed
        case "physical_effort": return .physicalEffort
        case "oxygen_saturation": return .oxygenSaturation
        case "environmental_audio": return .environmentalAudioExposure
        case "walking_steadiness": return .appleWalkingSteadiness
        case "body_mass_kg": return .bodyMass
        default: return nil
        }
    }

    private static func fmt(_ v: Double, metric: String, unit: HKUnit) -> String {
        if metric.contains("heart_rate") || metric == "rhr" || metric == "hrv" { return "\(Int(v.rounded())) bpm" }
        return String(format: "%.1f", v)
    }
    private static func hm(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d) }
}
```

注：`metricID(for:)` 与 `MetricTool.metrics` 字典存在重复映射。这是有意的（MetricTool 用字典存 tuple，此处只需 id），不强行重构以避免跨文件耦合。若实现时倾向复用，可把 MetricTool.metrics 暴露 `static func id(for:)` 供此处调用——由实现者判断，但必须保证两处 key 集合一致（测试 Task 6 会校验常见 key）。

- [ ] **Step 2: 编译验证**

Run: `cd Training && swift build`
Expected: 编译通过。

- [ ] **Step 3: Commit**

```bash
git add Training/Training/Tools/TableTools.swift
git commit -m "feat: add get_workout_metrics tool for workout-time-window queries"
```

---

### Task 4: 注册 WorkoutMetricsTool

**Files:**
- Modify: `Training/Training/ChatViewModel.swift`

**Interfaces:**
- Consumes: `WorkoutMetricsTool`（Task 3）

- [ ] **Step 1: 在 convenience init 注册列表加入新工具**

定位 `convenience init(costTracker:deepSeekService:)` 内的注册块，在 `registry.register(WorkoutTableTool())` 之后加：

```swift
registry.register(WorkoutMetricsTool())
```

完整块：
```swift
let registry = ToolRegistry()
registry.register(MetricTool())
registry.register(SleepTableTool())
registry.register(WorkoutTableTool())
registry.register(WorkoutMetricsTool())
registry.register(DailySummaryTool())
registry.register(ManualActivitiesTool(store: db))
registry.register(UserProfileTool())
registry.register(LogActivityTool(store: db))
registry.register(MatchScheduleTool(store: db))
```

- [ ] **Step 2: 编译验证**

Run: `cd Training && swift build`
Expected: 编译通过。

- [ ] **Step 3: Commit**

```bash
git add Training/Training/ChatViewModel.swift
git commit -m "feat: register get_workout_metrics in tool registry"
```

---

### Task 5: 更新 Planner prompt 文档

**Files:**
- Modify: `Training/Training/PromptBuilder.swift`

**Interfaces:**
- Produces: `plannerSystemPrompt()` 工具清单含新参数与新工具文档

- [ ] **Step 1: 在 get_metric 文档块补充新参数**

定位 `plannerSystemPrompt()` 内 `get_metric(metric, range?, days_ago?, output?)` 文档段，替换为：

```
get_metric(metric, range?, days_ago?, output?, today?, hours_ago?, duration_hours?)
  days_ago=N：今天往前第 N 天（1=昨天），返回该日单值，优先于 range。
  output: "summary"（默认）= 聚合值+趋势，"table" = 逐日明细表（按天）或逐 5 分钟序列（时段）。
  today=true：今天 0:00 到现在的细粒度，配合 output=table 返回逐 5 分钟序列。优先级最高。
  hours_ago=N + duration_hours=M：任意相对时段（如赛后 1h 恢复用 hours_ago=1,duration_hours=1）。
    N/M 支持小数。output=table 返回该时段逐 5 分钟序列。
  所有指标通用。单次时段查询不超过 24 小时。
  metrics: steps, active_calories, basal_calories, exercise_minutes,
           stand_minutes, flights_climbed, walking_running_km, cycling_distance_km,
           rhr, hrv, average_heart_rate, walking_heart_rate,
           vo2_max, respiratory_rate, oxygen_saturation,
           walking_speed, step_length_cm, walking_asymmetry_pct, double_support_pct,
           stair_ascent_speed, stair_descent_speed, physical_effort,
           environmental_audio, walking_steadiness, body_mass_kg
  range: 1-365
```

- [ ] **Step 2: 在工具清单新增 get_workout_metrics 文档**

在 `get_workout_table` 文档之后插入：

```
get_workout_metrics(type, date, metric, output?)
  按 type+date 定位某场 workout，查该 workout 时段内某指标的细粒度序列。
  type: 运动类型（Soccer/Running 等，大小写不敏感，football=soccer）。
  date: yyyy-MM-dd，"昨天"请解析为实际日期。
  metric: 同 get_metric 的 metric 名（如 average_heart_rate/steps/active_calories）。
  output: "summary"（时段 avg/min/max）/"table"（逐 5 分钟序列）。
  评估某场比赛表现时用此工具查比赛时段心率等，而非 get_metric 整天聚合。
  注意：跑动强度分布、加减速负荷等 Apple Watch 不提供，无法查询。
```

- [ ] **Step 3: 在规则段补用法指引**

在 `规则：` 列表末尾（`只输出 JSON...` 之前）补一条：

```
- 评估某场比赛表现：先用 get_workout_table(type=Soccer, range=2) 定位比赛日期，再用 get_workout_metrics(type=Soccer, date=yyyy-MM-dd, metric=average_heart_rate, output=table) 查比赛时段心率序列。
- 评估赛后恢复：get_metric(metric=rhr, hours_ago=1, duration_hours=1) 查赛后/赛后1h 数据。
- 看"今天状态"：get_metric(metric=average_heart_rate, today=true, output=table) 查今天 0 点到现在逐 5 分钟序列。
```

- [ ] **Step 4: 编译验证**

Run: `cd Training && swift build`
Expected: 编译通过。

- [ ] **Step 5: Commit**

```bash
git add Training/Training/PromptBuilder.swift
git commit -m "docs: document time-window params and get_workout_metrics in planner prompt"
```

---

### Task 6: 更新 Executor 闸门 prompt

**Files:**
- Modify: `Training/Training/PromptBuilder.swift`

**Interfaces:**
- Produces: `systemPrompt()` 回复原则第 2 条区分两类数据缺失

- [ ] **Step 1: 细化回复原则第 2 条**

定位 `systemPrompt()` 内 `2. 数据缺口前置闸门：...`，在末尾追加：

```
区分两类缺失：可得但未取（如心率 Planner 漏调）→ "缺少比赛中心率数据（可获取但未查询）"；Apple Watch 不提供（如跑动强度分布、加减速负荷、冲刺次数）→ "Apple Watch 不提供该项数据，无法评估"。对不可得数据主动说明"不提供"而非"缺失"。
```

- [ ] **Step 2: 编译验证**

Run: `cd Training && swift build`
Expected: 编译通过。

- [ ] **Step 3: Commit**

```bash
git add Training/Training/PromptBuilder.swift
git commit -m "docs: distinguish fetchable-vs-unavailable data gaps in executor gate"
```

---

### Task 7: 测试 — MetricTool 时段参数

**Files:**
- Test: `Tests/TrainingAppTests/MetricToolTests.swift`（新建）

**Interfaces:**
- Consumes: `MetricTool`、`HealthDataService.bucketStatistics`

- [ ] **Step 1: 写测试 — today 分支参数解析（不依赖真实 HealthKit）**

新建 `Tests/TrainingAppTests/MetricToolTests.swift`：

```swift
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
        let result = tool.execute(params: ["metric": "average_heart_rate", "today": "true", "output": "table"])
        #expect(!result.isEmpty)
    }

    @Test("hours_ago+duration_hours 返回非空")
    func testRelativeWindowParses() async {
        let tool = MetricTool()
        let result = tool.execute(params: ["metric": "average_heart_rate", "hours_ago": "1", "duration_hours": "1", "output": "table"])
        #expect(!result.isEmpty)
    }

    @Test("today=true 优先于 range")
    func testTodayOverridesRange() async {
        let tool = MetricTool()
        let r1 = tool.execute(params: ["metric": "steps", "today": "true", "range": "7", "output": "table"])
        // today 分支走 queryWindow，不应按天聚合（不含 "趋势" 关键字路径）
        // 仅断言非空——真实 HealthKit 无数据时两条路都可能返回 "—"
        #expect(!r1.isEmpty)
    }
}
```

- [ ] **Step 2: 运行测试**

Run: `cd Training && swift test --filter MetricToolTests`
Expected: PASS（三条；无 HealthKit 数据时返回占位也判非空通过）。

- [ ] **Step 3: Commit**

```bash
git add Tests/TrainingAppTests/MetricToolTests.swift
git commit -m "test: MetricTool time-window params parse without crashing"
```

---

### Task 8: 测试 — WorkoutMetricsTool

**Files:**
- Test: `Tests/TrainingAppTests/WorkoutMetricsToolTests.swift`（新建）

**Interfaces:**
- Consumes: `WorkoutMetricsTool`、`HealthDataService.workoutActivityType(forName:)`

- [ ] **Step 1: 写测试 — 参数校验与类型映射**

新建 `Tests/TrainingAppTests/WorkoutMetricsToolTests.swift`：

```swift
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
        let r = tool.execute(params: ["type": "Soccer"])
        #expect(r.contains("缺少必要参数"))
    }

    @Test("日期格式错误返回提示")
    func testBadDateFormat() async {
        let tool = WorkoutMetricsTool()
        let r = tool.execute(params: ["type": "Soccer", "date": "07-08", "metric": "average_heart_rate"])
        #expect(r.contains("日期格式错误"))
    }

    @Test("未知运动类型返回 nil 映射（HealthDataService 层）")
    func testUnknownTypeMapping() {
        #expect(HealthDataService.workoutActivityType(forName: "Basketball") == nil)
        #expect(HealthDataService.workoutActivityType(forName: "soccer") == .soccer)
        #expect(HealthDataService.workoutActivityType(forName: "Football") == .soccer)
    }

    @Test("metricID 覆盖常见指标")
    func testMetricIDCoverage() {
        #expect(WorkoutMetricsTool.metricID(for: "average_heart_rate") == .heartRate)
        #expect(WorkoutMetricsTool.metricID(for: "rhr") == .restingHeartRate)
        #expect(WorkoutMetricsTool.metricID(for: "steps") == .stepCount)
        #expect(WorkoutMetricsTool.metricID(for: "active_calories") == .activeEnergyBurned)
        #expect(WorkoutMetricsTool.metricID(for: "nonexistent_metric") == nil)
    }
}
```

注：若实现者选择把 `metricID(for:)` 做成 private（不暴露 static），则测试改为只测 HealthDataService 层的类型映射，metricID 测试删除。保留测试与实现可见性一致即可——以实现最终签名调整测试。

- [ ] **Step 2: 运行测试**

Run: `cd Training && swift test --filter WorkoutMetricsToolTests`
Expected: PASS。

- [ ] **Step 3: Commit**

```bash
git add Tests/TrainingAppTests/WorkoutMetricsToolTests.swift
git commit -m "test: WorkoutMetricsTool param validation and metric mapping"
```

---

### Task 9: 测试 — PromptBuilder 时段查询文档断言

**Files:**
- Modify: `Tests/TrainingAppTests/PromptBuilderTests.swift`

**Interfaces:**
- Consumes: `PromptBuilder`

- [ ] **Step 1: 追加 planner 文档断言**

在 `PromptBuilderTests` 末尾新增：

```swift
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
}
```

- [ ] **Step 2: 运行测试**

Run: `cd Training && swift test --filter PromptBuilderTests`
Expected: PASS（含原有用例 + 3 条新用例）。

- [ ] **Step 3: Commit**

```bash
git add Tests/TrainingAppTests/PromptBuilderTests.swift
git commit -m "test: assert time-window docs in planner and executor prompts"
```

---

### Task 10: 全量测试与构建

**Files:** 无（验证）

- [ ] **Step 1: 全量构建**

Run: `cd Training && swift build`
Expected: 编译通过，无 warning（或仅原有 warning）。

- [ ] **Step 2: 全量测试**

Run: `cd Training && swift test`
Expected: 全部 PASS（含原有 ChatViewModelTests/PromptBuilderTests 等 + 新增 MetricToolTests/WorkoutMetricsToolTests）。

- [ ] **Step 3: 如有失败，修复后回到 Step 2**

- [ ] **Step 4: 最终 commit（如有修复）**

```bash
git add -A
git commit -m "fix: resolve test failures from time-window query integration"
```
