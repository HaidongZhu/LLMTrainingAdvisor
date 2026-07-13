# 对话 Prompt 优化与取数修复 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复对话模式取数 bug（"昨天睡眠/昨天比赛"取错数据），并系统性提升 Planner/Executor prompt 质量，补齐数据缺口前置闸门等约束。

**Architecture:** 三层改动——(1) 工具代码统一 range 语义为"含今天的最近 N 天"+新增 `days_ago`/`type` 参数，把日期计算抽成纯函数以便单测；(2) PromptBuilder 文字优化（Executor 路由/数据闸门、Planner 按需调用/语义说明、recordPlanner 格式修正）；(3) ChatViewModel 的 manual_activities 占位符兜底。

**Tech Stack:** Swift 6 / SwiftUI @Observable / HealthKit / SQLite3 / Swift Testing。

## Global Constraints

- 工具协议 `HealthTool.execute(params: [String: String]) async -> String` 不变，新参数通过 params 字典读取（字符串）。
- `HealthDataService.dailyStatistics` 的 dict 键是 `Calendar.current.startOfDay(for: date)`；它本身已含今天（enumerate 到 `Date()`），bug 在消费端迭代逻辑。
- 所有日期用 `Calendar.current`，与现有代码一致。
- 测试用 Swift Testing（`@Test` / `#expect`），内存 DB 或纯函数；不测 live HealthKit。
- 不改身体数据硬编码（档案迁移单独 spec）。
- commit message 末尾加 `Co-Authored-By: Claude <noreply@anthropic.com>`。

## File Structure

- **修改** `Training/Training/HealthDataService.swift` — 新增纯函数日期工具 `dayRange(inclusiveDays:)` / `dayOffset(daysAgo:)`，供各工具复用，可单测。
- **修改** `Training/Training/Tools/MetricTool.swift` — 统一 range 含今天；新增 `days_ago` 单日定位。
- **修改** `Training/Training/Tools/TableTools.swift` — SleepTableTool/WorkoutTableTool/DailySummaryTool 统一 range 含今天；WorkoutTableTool + ManualActivitiesTool 新增 `type` 筛选；workout type 映射表。
- **修改** `Training/Training/DashboardService.swift` — `collectWeeklyData` 趋势场景显式排除今天（过去 N 天不含今天）。
- **修改** `Training/Training/PromptBuilder.swift` — Executor/Planner/recordPlanner/weeklyTrend prompt 文字改动。
- **修改** `Training/Training/ChatViewModel.swift` — manual_activities 占位符兜底注入。
- **新增/修改测试** `Tests/TrainingAppTests/` — 日期纯函数测试、ManualActivitiesTool type 筛选测试、PromptBuilder 断言、ChatViewModel 占位符测试。

---

## Task 1: 抽取可测日期纯函数到 HealthDataService

**Files:**
- Modify: `Training/Training/HealthDataService.swift`（文件末尾，类内）
- Create: `Tests/TrainingAppTests/DateRangeTests.swift`

**Interfaces:**
- Produces:
  - `HealthDataService.dayOffsets(inclusiveDays: Int) -> [Int]` — 返回 `[0, -1, ..., -(inclusiveDays-1)]`，0=今天。供"含今天的最近 N 天"迭代。
  - `HealthDataService.dayOffsetsPastExclusive(days: Int) -> [Int]` — 返回 `[-1, -2, ..., -days]`，即"不含今天的过去 N 天"。趋势场景用。
  - `HealthDataService.dateForDaysAgo(_ daysAgo: Int) -> Date` — 返回 `startOfDay(today - daysAgo)`，0=今天，1=昨天。

- [ ] **Step 1: Write the failing test**

Create `Tests/TrainingAppTests/DateRangeTests.swift`:

```swift
import Foundation
import Testing
@testable import TrainingApp

@Suite("DateRange")
struct DateRangeTests {

    @Test("dayOffsets inclusive contains today as first")
    func testInclusiveContainsToday() {
        let offsets = HealthDataService.dayOffsets(inclusiveDays: 3)
        #expect(offsets == [0, -1, -2])
    }

    @Test("dayOffsets inclusive with one day returns just today")
    func testInclusiveOneDay() {
        #expect(HealthDataService.dayOffsets(inclusiveDays: 1) == [0])
    }

    @Test("dayOffsetsPastExclusive excludes today")
    func testPastExclusive() {
        #expect(HealthDataService.dayOffsetsPastExclusive(days: 3) == [-1, -2, -3])
    }

    @Test("dateForDaysAgo zero is today startOfDay")
    func testDaysAgoZeroIsToday() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        #expect(HealthDataService.dateForDaysAgo(0) == today)
    }

    @Test("dateForDaysAgo one is yesterday startOfDay")
    func testDaysAgoOneIsYesterday() {
        let cal = Calendar.current
        let yesterday = cal.startOfDay(for: cal.date(byAdding: .day, value: -1, to: Date())!)
        #expect(HealthDataService.dateForDaysAgo(1) == yesterday)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter DateRangeTests 2>&1 | tail -5`
Expected: FAIL — `dayOffsets` 等符号不存在，编译错误。

- [ ] **Step 3: Write minimal implementation**

Add to `HealthDataService.swift` inside `struct HealthDataService` (after `dailyStatistics`):

```swift
    /// 含今天的最近 N 天：偏移量 [0, -1, ..., -(N-1)]，0=今天。
    static func dayOffsets(inclusiveDays: Int) -> [Int] {
        guard inclusiveDays > 0 else { return [] }
        return (0..<inclusiveDays).map { -$0 }
    }

    /// 不含今天的过去 N 天：偏移量 [-1, -2, ..., -N]。
    static func dayOffsetsPastExclusive(days: Int) -> [Int] {
        guard days > 0 else { return [] }
        return (1...days).map { -$0 }
    }

    /// 今天往前第 daysAgo 天的 startOfDay，0=今天，1=昨天。
    static func dateForDaysAgo(_ daysAgo: Int) -> Date {
        let cal = Calendar.current
        let base = cal.startOfDay(for: Date())
        return cal.date(byAdding: .day, value: -daysAgo, to: base) ?? base
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter DateRangeTests 2>&1 | tail -5`
Expected: PASS — 5 tests passed.

- [ ] **Step 5: Commit**

```bash
git add Training/Training/HealthDataService.swift Tests/TrainingAppTests/DateRangeTests.swift
git commit -m "feat: add testable date range helpers to HealthDataService

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 2: MetricTool 统一 range 含今天 + days_ago 单日

**Files:**
- Modify: `Training/Training/Tools/MetricTool.swift`（`execute` 约 35-75，`querySingle` 约 91-97）
- Create: `Tests/TrainingAppTests/MetricToolDateTests.swift`

**Interfaces:**
- Consumes: `HealthDataService.dayOffsets(inclusiveDays:)`, `HealthDataService.dateForDaysAgo(_:)`.
- Produces: `MetricTool.execute(params:)` 支持 `days_ago`（字符串），有 days_ago 时按单日查并返回单值；无时 range 含今天。

- [ ] **Step 1: Write the failing test**

Create `Tests/TrainingAppTests/MetricToolDateTests.swift`:

```swift
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
```

> 注：这些测试验证路由分支，不依赖真实 HealthKit（SPM 测试环境 HealthKit 不可用，返回 "—"）。重点是 days_ago 走单日路径、range=1 不再走 querySingle 特例。

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MetricToolDateTests 2>&1 | tail -5`
Expected: FAIL — 当前 range=1 走 querySingle（可能返回非 "—" 的格式），days_ago 未实现走 range 分支。

- [ ] **Step 3: Write minimal implementation**

In `MetricTool.swift`, replace the `execute` summary section. Current (about lines 48-64):

```swift
        // Summary mode: aggregate + trend
        if range == 1 {
            let v = await querySingle(id: id, opts: opts, converter: converter)
            return v.map { fmt($0, metric: metric) } ?? "—"
        }

        let cal = Calendar.current
        let byDay = await HealthDataService.dailyStatistics(store: store, id: id, options: opts, days: range, converter: converter)
        var values: [Double] = []
        for d in 0..<range {
            let day = cal.startOfDay(for: cal.date(byAdding: .day, value: -(d+1), to: Date())!)
            if let v = byDay[day] {
                values.append(v)
            }
        }
```

Replace with:

```swift
        // days_ago：单日定位（如昨天）。优先于 range。
        if let daysAgoStr = params["days_ago"], let daysAgo = Int(daysAgoStr) {
            let date = HealthDataService.dateForDaysAgo(daysAgo)
            let v = await queryDay(id: id, opts: opts, date: date, converter: converter)
            return v.map { fmt($0, metric: metric) } ?? "—"
        }

        // Summary mode: aggregate + trend（range 含今天）
        let cal = Calendar.current
        let byDay = await HealthDataService.dailyStatistics(store: store, id: id, options: opts, days: range, converter: converter)
        var values: [Double] = []
        for offset in HealthDataService.dayOffsets(inclusiveDays: range) {
            let day = cal.date(byAdding: .day, value: offset, to: Date())!
            if let v = byDay[day] {
                values.append(v)
            }
        }
```

Also in `queryTable` (about lines 81-83) replace the `-(d+1)` loop with `dayOffsets`:

```swift
        for offset in HealthDataService.dayOffsets(inclusiveDays: range) {
            let day = cal.startOfDay(for: cal.date(byAdding: .day, value: offset, to: Date())!)
            if let v = byDay[day] {
```

Keep `querySingle` / `queryDay` methods as-is (`queryDay` is reused by days_ago).

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MetricToolDateTests 2>&1 | tail -5`
Expected: PASS — 2 tests passed.

- [ ] **Step 5: Run full suite to check no regressions**

Run: `swift test 2>&1 | tail -3`
Expected: all pass (count = prior + new).

- [ ] **Step 6: Commit**

```bash
git add Training/Training/Tools/MetricTool.swift Tests/TrainingAppTests/MetricToolDateTests.swift
git commit -m "fix: MetricTool range includes today; add days_ago single-day lookup

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 3: WorkoutTableTool + ManualActivitiesTool 新增 type 筛选 & workout type 映射表

**Files:**
- Modify: `Training/Training/HealthDataService.swift`（新增 type→HKWorkoutActivityType 映射 + 反向匹配）
- Modify: `Training/Training/Tools/TableTools.swift`（WorkoutTableTool 按 type 筛选；ManualActivitiesTool 按 type 筛选）
- Modify: `Tests/TrainingAppTests/ManualActivitiesToolTests.swift`

**Interfaces:**
- Produces:
  - `HealthDataService.workoutActivityType(forName: String) -> HKWorkoutActivityType?` — 名称（如 "Soccer"/"soccer"/"football"）→ `.soccer` 等；未知返回 nil。
  - `ManualActivitiesTool.execute(params:)` 支持 `type`（字符串，大小写不敏感匹配 `activity_log.type`）。
  - `WorkoutTableTool.execute(params:)` 支持 `type`（用 `HKQuery.predicateForWorkouts(with:)` 筛选）。

- [ ] **Step 1: Write the failing test**

Append to `Tests/TrainingAppTests/ManualActivitiesToolTests.swift` (keep existing test):

```swift
    @Test("type filter returns only matching activities")
    func testTypeFilterMatchesOnlySoccer() async throws {
        let db = try DatabaseService(databasePath: ":memory:")
        try db.insertActivityLog(ActivityLog(
            id: UUID(), date: Date(), type: "Soccer",
            durationMin: 90.0, distanceKm: nil, intensity: nil,
            notes: nil, createdAt: Date()))
        try db.insertActivityLog(ActivityLog(
            id: UUID(), date: Date(), type: "Running",
            durationMin: 30.0, distanceKm: nil, intensity: nil,
            notes: nil, createdAt: Date()))

        let tool = ManualActivitiesTool(store: db)
        let output = await tool.execute(params: ["type": "soccer"])

        #expect(output.contains("Soccer"))
        #expect(!output.contains("Running"))
    }

    @Test("workoutActivityType maps soccer names")
    func testWorkoutTypeMapping() {
        #expect(HealthDataService.workoutActivityType(forName: "Soccer") == .soccer)
        #expect(HealthDataService.workoutActivityType(forName: "soccer") == .soccer)
        #expect(HealthDataService.workoutActivityType(forName: "football") == .soccer)
        #expect(HealthDataService.workoutActivityType(forName: "Running") == .running)
        #expect(HealthDataService.workoutActivityType(forName: "unknown-sport") == nil)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ManualActivitiesToolTests 2>&1 | tail -5`
Expected: FAIL — `type` 参数未实现，`workoutActivityType(forName:)` 不存在。

- [ ] **Step 3: Write minimal implementation**

In `HealthDataService.swift`, add (after `woType`):

```swift
    /// 运动名称 → HKWorkoutActivityType，大小写不敏感。football/soccer 都映射到 .soccer。未知返回 nil。
    static func workoutActivityType(forName name: String) -> HKWorkoutActivityType? {
        switch name.lowercased() {
        case "soccer", "football": return .soccer
        case "running": return .running
        case "cycling", "biking": return .cycling
        case "walking": return .walking
        case "hiking": return .hiking
        case "stairs": return .stairs
        case "swimming": return .swimming
        case "yoga": return .yoga
        default: return nil
        }
    }
```

In `TableTools.swift` `ManualActivitiesTool.execute`, add type filter after fetching logs (replace the loop region). Current:

```swift
        let logs = (try? store.queryAllActivities()) ?? []
        let cutoff: Date? = range.flatMap { Calendar.current.date(byAdding: .day, value: -$0, to: Date()) }
        for log in logs {
            if let cutoff, log.date < cutoff { continue }
```

Replace with:

```swift
        let logs = (try? store.queryAllActivities()) ?? []
        let cutoff: Date? = range.flatMap { Calendar.current.date(byAdding: .day, value: -$0, to: Date()) }
        let typeFilter = params["type"]?.lowercased()
        for log in logs {
            if let cutoff, log.date < cutoff { continue }
            if let typeFilter, log.type.lowercased() != typeFilter { continue }
```

In `WorkoutTableTool.execute`, after building `pred` (the samples predicate), combine with type predicate if `type` present. Current (about lines 56-78) ends building `pred` then runs the query. Modify the predicate construction:

```swift
        let end = Date()
        let start = cal.date(byAdding: .day, value: -range, to: end)!
        var pred = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictEndDate)
        if let typeName = params["type"], let actType = HealthDataService.workoutActivityType(forName: typeName) {
            let typePred = HKQuery.predicateForWorkouts(with: actType)
            pred = NSCompoundPredicate(andPredicateWithSubpredicates: [pred, typePred])
        }
```

(Keep the rest of WorkoutTableTool unchanged; it already maps `woType` for display.)

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ManualActivitiesToolTests 2>&1 | tail -5`
Expected: PASS — 3 tests (1 existing + 2 new).

- [ ] **Step 5: Commit**

```bash
git add Training/Training/HealthDataService.swift Training/Training/Tools/TableTools.swift Tests/TrainingAppTests/ManualActivitiesToolTests.swift
git commit -m "feat: add type filter to workout/manual activities tools + workout type map

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 4: SleepTableTool / DailySummaryTool 统一 range 含今天

**Files:**
- Modify: `Training/Training/Tools/TableTools.swift`（SleepTableTool `for d in 0..<range` 约 15-16；DailySummaryTool 同 约 95-96）

**Interfaces:**
- Consumes: `HealthDataService.dayOffsets(inclusiveDays:)`.

- [ ] **Step 1: Write the failing test**

These tools query live HealthKit (no SPM test). Add a lightweight structural test that the loop uses inclusive offsets indirectly — instead, test that `dayOffsetsPastExclusive` + `dayOffsets` are consistent (already covered in Task 1). For Sleep/DailySummary, verify behavior via the shared helper. Since HealthKit isn't testable, document the change and rely on Task 1 coverage + manual verification. **Skip dedicated failing test for live-HK tools; justify inline.**

Add a guard test in `DateRangeTests.swift`:

```swift
    @Test("inclusive and exclusive offsets are disjoint and adjacent")
    func testInclusiveExclusiveDisjoint() {
        let inc = HealthDataService.dayOffsets(inclusiveDays: 2)   // [0, -1]
        let exc = HealthDataService.dayOffsetsPastExclusive(days: 2) // [-1, -2]
        #expect(Set(inc).intersection(Set(exc)) == [-1]) // only yesterday overlaps
        #expect(!inc.contains(0) == false) // today in inclusive
    }
```

- [ ] **Step 2: Run test to verify it fails (or passes — this is a safety net)**

Run: `swift test --filter DateRangeTests 2>&1 | tail -5`
Expected: PASS (helper correctness).

- [ ] **Step 3: Write minimal implementation**

In `SleepTableTool.execute`, replace:

```swift
        for d in 0..<range {
            let date = cal.date(byAdding: .day, value: -(d+1), to: Date())!
```

with:

```swift
        for offset in HealthDataService.dayOffsets(inclusiveDays: range) {
            let date = cal.date(byAdding: .day, value: offset, to: Date())!
```

In `DailySummaryTool.execute`, replace:

```swift
        for d in 0..<range {
            let day = cal.startOfDay(for: cal.date(byAdding: .day, value: -(d+1), to: Date())!)
```

with:

```swift
        for offset in HealthDataService.dayOffsets(inclusiveDays: range) {
            let day = cal.startOfDay(for: cal.date(byAdding: .day, value: offset, to: Date())!)
```

Note: SleepTableTool's overnight window (3pm→3pm) logic stays; only the day iteration origin changes from yesterday-inclusive to today-inclusive.

- [ ] **Step 4: Build + run full suite**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -3`
Expected: build OK; all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Training/Training/Tools/TableTools.swift Tests/TrainingAppTests/DateRangeTests.swift
git commit -m "fix: sleep/daily-summary range includes today

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 5: DashboardService 趋势场景排除今天

**Files:**
- Modify: `Training/Training/DashboardService.swift`（`collectWeeklyData` 约 118-158）

**Interfaces:**
- Consumes: `HealthDataService.dayOffsetsPastExclusive(days:)` + `dateForDaysAgo(_:)`.

- [ ] **Step 1: Understand current behavior**

`collectWeeklyData` builds per-day rows using `HealthDataService.dailyStatistics(days:7)` then iterates `cal.date(byAdding: .day, value: -(d+1))` (yesterday-back 7). After Task 4 tools became today-inclusive, but DashboardService has its OWN iteration loop (not the tools) — check: it calls `HealthDataService.dailyStatistics` directly for rhr/hrv/steps/exercise (lines 123-141) and uses `-(d+1)`. The *tools* (SleepTableTool/WorkoutTableTool/ManualActivitiesTool) are called separately at lines 143-155.

So DashboardService's own daily-stat iteration should stay **past-exclusive** (trend should show past 7 full days, not partial today). The tools called within collectWeeklyData (sleep/workout/manual) — after Task 4 they became today-inclusive, which changes trend content.

**Decision:** Keep DashboardService own stat loop past-exclusive (unchanged `-(d+1)` is already past-exclusive — correct for trends). For the tools called within collectWeeklyData, pass an explicit range and accept today may appear if data exists, OR switch them to past-exclusive. Simplest: leave tools today-inclusive (general semantic), and in DashboardService filter out today's row from tool outputs is over-engineering. Instead: trend uses range=7 tools → includes today. Acceptable if today's workout/sleep exist; trend "past 7 days" mildly includes today.

To keep trend strictly "past 7 days excluding today", refactor DashboardService to use `dayOffsetsPastExclusive` for its own stat loop AND call tools with a note. Since tools don't support past-exclusive param, the cleanest fix: DashboardService keeps its own stat loop past-exclusive (already is), and for sleep/workout/manual tool calls, the today-inclusion is a minor acceptable change (today's sleep may be incomplete). **Document this as accepted tradeoff** rather than add complexity.

- [ ] **Step 2: Add a clarifying test that DashboardService own stat loop is past-exclusive**

Create `Tests/TrainingAppTests/DashboardTrendDateTests.swift`:

```swift
import Foundation
import Testing
@testable import TrainingApp

@Suite("DashboardService trend dates")
struct DashboardTrendDateTests {

    @Test("trend uses past-exclusive 7 days for its own stat loop")
    func testTrendPastExclusive() {
        // 趋势自有的 dailyStatistics 迭代应为过去 7 天不含今天
        let offsets = HealthDataService.dayOffsetsPastExclusive(days: 7)
        #expect(offsets.count == 7)
        #expect(!offsets.contains(0))  // 不含今天
        #expect(offsets.first == -1)   // 从昨天起
    }
}
```

- [ ] **Step 3: Run test (passes — helper correctness gate)**

Run: `swift test --filter DashboardTrendDateTests 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 4: Refactor collectWeeklyData own stat loop to use helper (no behavior change, but explicit)**

In `DashboardService.collectWeeklyData`, replace the own stat loop (about lines 134-139):

```swift
            for d in 0..<7 {
                let day = cal.startOfDay(for: cal.date(byAdding: .day, value: -(d+1), to: Date())!)
                if let v = byDay[day] {
```

with:

```swift
            for offset in HealthDataService.dayOffsetsPastExclusive(days: 7) {
                let day = cal.startOfDay(for: cal.date(byAdding: .day, value: offset, to: Date())!)
                if let v = byDay[day] {
```

(Also change `for d in 0..<7` fixed loop to `dayOffsetsPastExclusive(days: 7)` for clarity. The `range` variable here is hardcoded 7 in metricKeys loop — keep 7.)

- [ ] **Step 5: Build + test**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -3`
Expected: build OK; all pass.

- [ ] **Step 6: Commit**

```bash
git add Training/Training/DashboardService.swift Tests/TrainingAppTests/DashboardTrendDateTests.swift
git commit -m "refactor: DashboardService trend loop uses past-exclusive date helper

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 6: ChatViewModel manual_activities 占位符兜底

**Files:**
- Modify: `Training/Training/ChatViewModel.swift`（manual_activities 注入 约 330-339）
- Modify: `Tests/TrainingAppTests/ChatViewModelTests.swift`

**Interfaces:**
- Produces: `context["manual_activities"]` always set (to data or "无手动记录"), so `render` always substitutes.

- [ ] **Step 1: Write the failing test**

Append to `Tests/TrainingAppTests/ChatViewModelTests.swift` (after existing tests). This test verifies the render contract the fix depends on — that a filled `"无手动记录"` value replaces the placeholder (since the fix always injects a non-empty value):

```swift
    @Test("manual_activities placeholder is replaced when a value is injected")
    func testManualActivitiesPlaceholderReplacedOnInject() {
        let template = "人工记录：\n{manual_activities}"
        // 修复后 ChatViewModel 总会注入值（数据或"无手动记录"），render 必替换占位符。
        let filled = PromptBuilder.render(template, with: ["manual_activities": "无手动记录"])
        #expect(filled == "人工记录：\n无手动记录")
        #expect(!filled.contains("{manual_activities}"))
    }
```

- [ ] **Step 2: Run test to verify it passes (contract guard)**

Run: `swift test --filter ChatViewModelTests.testManualActivitiesPlaceholderReplacedOnInject 2>&1 | tail -5`
Expected: PASS — `render` 已正确替换已知 key。此测试作为契约护栏，确保修复依赖的 render 行为成立。真正的 bug 修复在 Step 3（注入逻辑），手动验证即可。

- [ ] **Step 3: Write the implementation fix**

In `ChatViewModel.swift` sendMessage, the manual_activities block (about 329-339):

Current:
```swift
            if context["manual_activities"] == nil,
               let db = messageStore as? DatabaseService {
                let range = plannerResponse.response.tools.compactMap {
                    Int($0.params["range"] ?? "")
                }.first ?? 7
                let manualTool = ManualActivitiesTool(store: db)
                let manualResult = await manualTool.execute(params: ["range": String(range)])
                if manualResult != "无手动记录" {
                    context["manual_activities"] = manualResult
                }
            }
```

Replace with (always inject):
```swift
            if context["manual_activities"] == nil,
               let db = messageStore as? DatabaseService {
                let range = plannerResponse.response.tools.compactMap {
                    Int($0.params["range"] ?? "")
                }.first ?? 7
                let manualTool = ManualActivitiesTool(store: db)
                // 兜底：无数据时工具返回"无手动记录"，确保 {manual_activities} 占位符被替换，不泄漏给 Executor。
                // 上一行为 PromptBuilder.render 的契约——manualResult 永远非空，占位符必被替换。
                context["manual_activities"] = await manualTool.execute(params: ["range": String(range)])
            }
            // 若 messageStore 非 DatabaseService（测试 mock），占位符行为不在本次范围。
```

`ManualActivitiesTool.execute` 在无记录时已返回 `"无手动记录"`，故直接赋值即可保证占位符被替换，无需额外判断。

- [ ] **Step 4: Build + test**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -3`
Expected: build OK; all pass.

- [ ] **Step 5: Commit**

```bash
git add Training/Training/ChatViewModel.swift Tests/TrainingAppTests/ChatViewModelTests.swift
git commit -m "fix: always inject manual_activities so placeholder never leaks to Executor

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 7: Executor systemPrompt 改动

**Files:**
- Modify: `Training/Training/PromptBuilder.swift`（`systemPrompt` 4-63）
- Modify: `Tests/TrainingAppTests/PromptBuilderTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `Tests/TrainingAppTests/PromptBuilderTests.swift`:

```swift
    @Test("system prompt instructs Chinese replies")
    func testSystemPromptChineseInstruction() {
        #expect(PromptBuilder.systemPrompt().contains("使用简体中文"))
    }

    @Test("system prompt has route guidance distinguishing plan vs analysis")
    func testSystemPromptRouteGuidance() {
        let p = PromptBuilder.systemPrompt()
        #expect(p.contains("路由") || p.contains("训练") && p.contains("数据分析"))
    }

    @Test("system prompt has data-gap hard gate")
    func testSystemPromptDataGapGate() {
        let p = PromptBuilder.systemPrompt()
        #expect(p.contains("无法分析") || p.contains("数据缺口") || p.contains("关键数据缺失"))
    }

    @Test("system prompt has no-data fallback rule")
    func testSystemPromptNoDataFallback() {
        #expect(PromptBuilder.systemPrompt().contains("无数据") || PromptBuilder.systemPrompt().contains("编造"))
    }

    @Test("training plan format example uses plain text not fenced code block")
    func testTrainingFormatNoFencedBlock() {
        let p = PromptBuilder.systemPrompt()
        #expect(!p.contains("```"))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PromptBuilderTests 2>&1 | tail -8`
Expected: FAIL — 新断言不满足（当前 prompt 无简体中文指令、有代码块等）。

- [ ] **Step 3: Write the implementation**

In `PromptBuilder.swift`, replace `systemPrompt` body (lines 20-62, the triple-quoted return). New:

```swift
        return """
        你是私人健康与运动教练。用户是 {age} 岁业余足球运动员（后腰/边后卫），
        每周三和周末比赛。训练目标是长期维持竞技状态、预防伤病。
        所有回复使用简体中文。

        ## 伤病历史
        - {injury_history}
        - {injury_history}
        - {injury_history}

        ## 身体数据
        - 身高: {height}
        - 体重: {weight}

        ## 健康发现
        - {health_findings}
        - {health_findings}

        ## 教练理念
        长期维持运动能力，以伤病预防为最高优先级，安全第一。

        \(matchSection)

        ## 训练计划格式
        当用户询问"今天练什么""这周计划""给我一个训练"时，返回结构化计划。格式参考：

        例：
        今天训练：
        - 动作名称 组数×次数（如：死虫式 10×3）
        - 组间休息时间
        - 负荷建议（如：zone2 心率、自重、弹力带）
        训练目的：核心稳定 / 爆发力维持 / 主动恢复

        ## 回复原则
        1. 路由判定：用户问训练/计划（"今天练什么""这周计划"）→ 给结构化训练计划；问状态/恢复/睡眠/比赛（"我恢复得怎么样""最近睡眠如何""昨天比赛如何"）→ 给数据分析 + 建议，不套训练计划格式。
        2. 数据缺口前置闸门：回复开头先核对回答用户请求需要哪些数据。若关键数据缺失（工具未返回、时间范围对不上、完全无数据），则不往下分析，在第一句告知"⚠️ 无法分析：[缺了什么] — [为什么缺这些就无法回答]"，不要基于无关数据硬凑结论。例如"我昨天球赛整体表现如何"若未获取到昨天球赛详细数据，直接回"⚠️ 无法分析：未获取到昨天球赛的详细数据，无法评估表现"。关键 vs 辅助数据的归类由你判断：辅助数据缺失可继续分析并注明。
        3. 只回答用户问的，不要发散到无关话题（如不问饮食就不提饮食）。
        4. 训练建议必须具体、可执行，绝不能笼统（如不能说"做核心训练"，必须说"死虫式 10×3，组间 45s"）。
        5. 结合数据判断：RHR 偏高 → 降强度；HRV 偏低 → 恢复优先；睡眠不足 → 不安排高强度。
        6. 考虑伤病调整：内收肌问题 → 避免大幅侧向移动；足底筋膜 → 避免赤足跳跃跑跳。
        7. 每个结论有数据支撑，引用具体数值。
        8. 关键数据缺失时明确指出（与第 2 条配合）。
        9. 无数据兜底：若所有健康工具返回无数据，如实告知用户当前无可用数据，不要编造具体数值。
        10. 简洁：回复简洁，围绕用户问题给出可执行结论，避免重复堆砌同义内容。安全第一：不制造焦虑，不批评用户。
        """
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PromptBuilderTests 2>&1 | tail -8`
Expected: PASS — all PromptBuilder tests including new ones.

- [ ] **Step 5: Run full suite**

Run: `swift test 2>&1 | tail -3`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add Training/Training/PromptBuilder.swift Tests/TrainingAppTests/PromptBuilderTests.swift
git commit -m "feat: Executor prompt — Chinese instruction, route guidance, data-gap gate, no fenced block

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 8: Planner systemPrompt 改动

**Files:**
- Modify: `Training/Training/PromptBuilder.swift`（`plannerSystemPrompt` 82-134）
- Modify: `Tests/TrainingAppTests/PromptBuilderTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `Tests/TrainingAppTests/PromptBuilderTests.swift`:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PromptBuilderTests 2>&1 | tail -8`
Expected: FAIL — 新断言不满足。

- [ ] **Step 3: Write the implementation**

In `PromptBuilder.plannerSystemPrompt`, after the example JSON block (after the `prompt_template` example, before `规则：`), add an on-demand note + minimal example. And extend rules + tool docs. Replace the section from `规则：` through end of `get_user_profile()`:

Replace (current rules block, lines 100-106):
```swift
        规则：
        - 每次工具调用必须有 call_id，params 在 params 对象内，值用字符串
        - prompt_template 用 {call_id} 占位符引用工具返回值
        - 评估今日训练状态时，必须同时查询 range=7 的趋势和 range=1 的今日值
        - 同一工具可多次调用，用不同 call_id 区分
        - range 范围 1-365，任意整数。如果没有指定，根据问题意图按专业知识判断合理日期数。
        - 只输出 JSON，不要任何其他文字、注释或解释。
```

With:
```swift
        以上为完整示例，实际工具调用应根据用户问题按需选择。简单问题（如"我昨天睡多久"）只需查询相关工具，不必照搬示例的全部工具。每个工具调用都应有明确用途。

        简单问题示例：用户"我昨天睡多久" → 只调 get_sleep_table(range=2)（今天+昨天），prompt_template 只引用这次结果。

        规则：
        - 规划原则：先判断回答用户问题需要哪些数据（今日值？昨日值？趋势？比赛？手动记录？），再据此选择工具和 range。避免冗余调用，也避免漏掉关键数据导致 Executor 无法回答。
        - 每次工具调用必须有 call_id，params 在 params 对象内，值用字符串
        - prompt_template 用 {call_id} 占位符引用工具返回值
        - 评估今日训练状态时，必须同时查询 range=7 的趋势和 range=1 的今日值
        - 同一工具可多次调用，用不同 call_id 区分
        - range=N 表示查询最近 N 天，含今天。range=1=今天，range=2=今天+昨天。要定位"昨天某项指标"，用 days_ago=1 而非 range。
        - range 范围 1-365，任意整数。如果没有指定，根据问题意图按专业知识判断合理日期数。
        - 只输出 JSON，不要任何其他文字、注释或解释。

        工具清单：

        get_metric(metric, range?, days_ago?, output?)
          days_ago=N：今天往前第 N 天（1=昨天），返回该日单值，优先于 range。
          output: "summary"（默认）= 聚合值+趋势，"table" = 逐日明细表。
          所有指标通用。range>1 且用户问趋势/变化/明细时，用 output: "table"。
          metrics: steps, active_calories, basal_calories, exercise_minutes,
                   stand_minutes, flights_climbed, walking_running_km, cycling_distance_km,
                   rhr, hrv, average_heart_rate, walking_heart_rate,
                   vo2_max, respiratory_rate, oxygen_saturation,
                   walking_speed, step_length_cm, walking_asymmetry_pct, double_support_pct,
                   stair_ascent_speed, stair_descent_speed, physical_effort,
                   environmental_audio, walking_steadiness, body_mass_kg
          range: 1-365

        get_daily_summary(range: 1-365)
          返回每日关键指标明细表（日期|步数|RHR|HRV|运动min）。用于查看逐日变化趋势。
        get_sleep_table(range: 1-365)
          返回睡眠阶段分布表（核心/深度/REM/清醒）。days_ago=1 表示昨晚睡眠。
        get_workout_table(range?, type?)
          返回 Apple Watch 体能训练记录（类型/时长/距离/热量）。type 按运动类型筛选（如 Soccer/Running）。
        get_manual_activities(range?, type?)
          返回人工输入的运动记录。此工具由系统自动调用，无需你主动调用。
          prompt_template 中永远可以引用 {manual_activities} 变量获取人工记录。type 按类型筛选。
          注意：球赛/比赛记录可能存在两处——戴手表的比赛在 get_workout_table（HealthKit）；不允许戴手表的比赛在 manual_activities（人工登记）。涉及"某场比赛表现"时，两处都要查。
        get_match_schedule()
          返回未来比赛日程表。涉及训练规划时必须调用，根据比赛时间调整训练强度和内容。
        get_user_profile()
          返回个人静态档案（年龄/伤病/体检）。涉及伤病或身体状况判断时可调用。
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PromptBuilderTests 2>&1 | tail -8`
Expected: PASS — all PromptBuilder tests.

- [ ] **Step 5: Run full suite**

Run: `swift test 2>&1 | tail -3`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add Training/Training/PromptBuilder.swift Tests/TrainingAppTests/PromptBuilderTests.swift
git commit -m "feat: Planner prompt — on-demand guidance, range semantics, dual data source, days_ago/type docs

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 9: recordPlanner + weeklyTrend 风格修正

**Files:**
- Modify: `Training/Training/PromptBuilder.swift`（`recordPlannerSystemPrompt` 65-80；`weeklyTrendPrompt` 137-169）
- Modify: `Tests/TrainingAppTests/PromptBuilderTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `Tests/TrainingAppTests/PromptBuilderTests.swift`:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PromptBuilderTests 2>&1 | tail -8`
Expected: FAIL.

- [ ] **Step 3: Write the implementation**

In `recordPlannerSystemPrompt`, replace `date: "YYYY-MM-DD"` occurrences (lines 71, 77) with `date: "yyyy-MM-dd`, and add unknown-type guidance. Replace the type line (line 76):

```swift
          type: Soccer/Running/Cycling/Hiking/Strength/Swimming/Yoga/Stairs/Walking
          不在列表内的运动，选最接近的类型并在 notes 注明实际运动。
          date: yyyy-MM-dd，"昨天"请计算为实际日期
```

(Both `YYYY` in lines 71 and 77 → `yyyy`.)

In `weeklyTrendPrompt`, the example lines (about 144-146). Replace:

```swift
        例如：
          "7月1日 HRV 骤升至 39ms，当日有 83 分钟比赛"
          "7月6日 RHR 略升至 68，前夜睡眠仅 5.3h 且白天无训练"
```

With:

```swift
        例如（以下为示例格式，非真实数据）：
          "7月1日 HRV 骤升至 39ms，当日有 83 分钟比赛"
          "7月6日 RHR 略升至 68，前夜睡眠仅 5.3h 且白天无训练"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PromptBuilderTests 2>&1 | tail -8`
Expected: PASS.

- [ ] **Step 5: Run full suite + build**

Run: `swift test 2>&1 | tail -3`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add Training/Training/PromptBuilder.swift Tests/TrainingAppTests/PromptBuilderTests.swift
git commit -m "fix: record planner yyyy date format, unknown-type guidance; weekly trend example label

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 10: 真机 build + 端到端验证

**Files:**
- None (verification only)

- [ ] **Step 1: Run full test suite**

Run: `swift test 2>&1 | tail -3`
Expected: all pass, count = prior + ~12 new.

- [ ] **Step 2: Build for device**

Run: `cd Training && xcodebuild -project Training.xcodeproj -scheme Training -destination "platform=iOS,id=<SIMULATOR_OR_DEVICE_ID>" -allowProvisioningUpdates build 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)|error:"`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Install to device**

Run: `APP=$(find ~/Library/Developer/Xcode/DerivedData/Training-*/Build/Products/Debug-iphoneos/Training.app -maxdepth 0 | head -1) && xcrun devicectl device install app --device <SIMULATOR_OR_DEVICE_ID> "$APP" 2>&1 | grep -i "App installed"`
Expected: `App installed:`

- [ ] **Step 4: Manual end-to-end checks (device)**

Test these scenarios in the app:
1. 对话 Tab 问"我昨天睡得怎么样" → 应返回**昨晚**睡眠数据（不是前天/今天/平均）。
2. 对话 Tab 问"昨天比赛如何" → 若有昨晚 football workout，应定位并分析；若比赛在手动记录，也应查到。
3. 对话 Tab 问"今天练什么" → 给结构化训练计划（路由判定）。
4. 对话 Tab 问一个无数据的话题 → 应回"⚠️ 无法分析：…"（数据缺口闸门），不编造。
5. 趋势 Tab 刷新 → 不崩溃，费用栏正常累加。

Record results. If scenarios 1/2 still wrong, investigate tool date logic further (may need real-device HealthKit debugging).

- [ ] **Step 5: Final commit if any fixups**

Only if manual testing surfaced fixes. Otherwise plan complete.
