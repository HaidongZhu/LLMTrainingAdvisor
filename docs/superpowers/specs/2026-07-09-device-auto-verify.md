# 真机自动化验证机制 设计（spec）

## 背景

对话链路改 prompt 后，每次都要人工装手机、发一句话、人眼看回复判断对不对。用户希望我（LLM）自己全程跑通完整链路（Planner 决策 + 工具执行 + Executor 回复），拉回完整调用链数据，由 LLM 读 log 判断对错，没问题了用户再人工验证。

## 已确认决策（brainstorming）

1. **驱动方式**：复用现有 `SelfTestRunner` + `dev_flow.sh selftest`，改 scenarios 重装手机。不走文件驱动、不走 XCUITest 注入输入框。
2. **工具结果落日志**：selftest.log 里每个工具调用后打一行 `TOOL_RESULT|<callId>|<完整返回值>`，包括心率序列、睡眠表等。
3. **判断方式 = LLM 读 log 判断**，不做规则断言。不硬编码"期望工具集"——拉回 log 后由 LLM 直接读、判断这轮调用链对不对，把结论给用户。XCUITest / dev_flow 只负责"跑完拉回 log"，不做语义断言。

## 现状分析

`SelfTestRunner.runOne` 已打结构化日志：`USER / PLANNER_RAW(完整JSON) / TOOL 名+参数 / TEMPLATE / EXECUTOR(完整回复) / COST`，写到 `Documents/selftest-N.log`，由 `dev_flow.sh selftest` 拉回本地。XCUITest 启动带 `singleScenario` 的 host view，靠 `SELFTEST_DONE` accessibility identifier 等完成。

关键缺口：
- **工具执行结果没落日志**。现在只有 TOOL 名+参数，缺 `TOOL_RESULT`。但数据其实已存在一条 system ChatMessage 的 `fullRequest` 里（ChatViewModel line 342-345，格式 `callId:\n<result>\n\n---\n\n`，content 含 "🔧 工具查询"）——只需在 runOne 识别这条 message 并解析。
- **selftest 两个 makeViewModel 都漏注册 `WorkoutMetricsTool()`**（现有 bug）。这导致 selftest 跑"昨天比赛表现"时新工具不可用，Planner 调了也执行不了。必须补。
- **场景硬编码**，要跑新句子得改代码重装（已接受的方案，非缺口）。

## 设计

### 1. SelfTestScenario 结构化

把 scenarios 从 `(String, (ChatViewModel) async -> Void)` 元组改成结构体，便于后续扩展，并让新增句子更清晰：

```swift
struct SelfTestScenario {
    let name: String
    let message: String
    let useMatchVM: Bool   // 是否用注入比赛日程的 VM
}
```

`runAll` / `runSingle` 用 `[SelfTestScenario]` 数组，`scenario` 闭包统一 `await vm.sendMessage(scenario.message)`。

### 2. runOne 补打 TOOL_RESULT

在 `runOne` 末尾（COST 行之前），识别工具结果 message 并逐个打 log：

```swift
// 工具执行结果（来自 "🔧 工具查询" system message 的 fullRequest，格式 callId:\n<result>\n\n---\n\n）
let toolResultMsg = msgs.last(where: { $0.role == "system" && $0.content.contains("🔧 工具查询") })
if let tr = toolResultMsg, !tr.fullRequest.isEmpty {
    // fullRequest 形如 "callId1:\nresult1\n\n---\n\ncallId2:\nresult2"
    let chunks = tr.fullRequest.components(separatedBy: "\n\n---\n\n")
    for chunk in chunks {
        if let colonRange = chunk.range(of: ":\n") {
            let callId = String(chunk[..<colonRange.lowerBound])
            let result = String(chunk[colonRange.upperBound...])
            buf.append("TOOL_RESULT|\(callId)|\(result.replacingOccurrences(of: "\n", with: "\\n"))")
        }
    }
}
```

### 3. 补注册 WorkoutMetricsTool

`makeViewModel` 和 `makeViewModelWithMatch` 的 registry 注册块，在 `WorkoutTableTool()` 之后加 `registry.register(WorkoutMetricsTool())`。

### 4. 新增场景

在 scenarios 数组加一项：
```swift
SelfTestScenario(name: "昨天比赛表现", message: "我昨天比赛整体表现如何", useMatchVM: false)
```

该场景是本次时段查询 + 赛前恢复基础 prompt 改动的验证目标。

### 5. selftest.log 完整格式（验证依据）

每个场景一个块：
```
=== SCENARIO|<i>|<name> ===
USER|<用户原话>
PLANNER_RAW|<Planner 返回的完整 JSON>
TOOL|<toolName> <paramKey>=<value> ...        （每个工具一行）
TOOL_RESULT|<callId>|<工具完整返回值>          （每个工具一行）
TEMPLATE|<prompt_template>
EXECUTOR|<Executor 最终回复>
COST|in=..|out=..|cost=..|time=..s
```

判断流程：`dev_flow.sh selftest` 拉回所有 `selftest-*.log` → LLM 读 log → 针对 USER 那句话，逐项检查 PLANNER_RAW 调的工具是否充分、TOOL_RESULT 是否真取到数据、EXECUTOR 回复是否合理且无"缺数据"误报 → 给出结论。

## 涉及文件

- `Training/Training/SelfTest/SelfTestRunner.swift`（修改）：SelfTestScenario 结构体、runOne 补 TOOL_RESULT、补注册 WorkoutMetricsTool、新增场景。
- 无新增文件，无 prompt 改动（本次 prompt 改动已在之前 commit）。

## 范围

纯验证基础设施增强，不动业务逻辑。完成后流程：改 scenarios 重装 → `bash dev_flow.sh selftest` → 拉 log → LLM 判断。

## 验证标准

- `swift build` 通过。
- 新场景"昨天比赛表现"出现在 selftest.log，且 log 里有 `TOOL_RESULT|` 行（说明工具结果落进去了）。
- 实际跑通后，log 里能看到 `get_workout_metrics` 的 TOOL_RESULT 含心率序列、`get_metric`/`get_sleep_table` 的 TOOL_RESULT 含赛前数据。
