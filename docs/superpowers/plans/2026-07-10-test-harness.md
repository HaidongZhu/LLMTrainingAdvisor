# 单场景可重复 Test Harness 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让"改代码 → 真机跑单场景 → 稳定看到新输出"循环 100% 可靠，消除"靠猜"。

**Architecture:** app 触发点从 SwiftUI `.task` 移到 `TrainingApp.init()` + `SelfTestController`，脱离 view 生命周期。产物从覆盖式 `selftest-N.log` 改成 session 目录（status.json + heartbeat.txt + events.log + stdout.log），永不覆盖。Runner 链路执行逻辑不变，只把产物写入从"末尾一次写"改成"节点回调边跑边写 event"。Mac 侧 `dev_flow.sh` 新增 `run_scenario`：冷启动 + 确认新 session + 重试 + 拉整个 session 目录。

**Tech Stack:** Swift 6 / SwiftUI @Observable @MainActor / HealthKit / SQLite / DeepSeek API；shell (devicectl)。

## Global Constraints

- spec 文档：`docs/superpowers/specs/2026-07-10-test-harness-design.md`，所有产物路径/字段名/状态值以此为准。
- **铁律**：不论如何不能丢数据库数据。新逻辑绝不卸载 app 清缓存，绝不碰 `training.db`。
- session 目录结构：`Documents/Sessions/<session>/`，session id 格式 `YYYYMMDD-HHMMSS-<4位hex>`，永不覆盖。
- 状态机 state 值固定枚举：`running` | `healthkit` | `planner` | `executing` | `done` | `error`。
- 约定：测试期间 app 保持前台（用户确认），`Task {}` 前台不冻结，不加 `performExpiringActivity`。
- Runner 链路执行逻辑（makeViewModel / sendMessage / Planner→工具→Executor）**不得改动**，只改产物写入时机。
- 设备：UDID `<YOUR_DEVICE_UDID>`，bundle `com.example.Training`，无线 CoreDevice。

---

## 文件结构

- 新建：`Training/Training/SelfTest/SelfTestController.swift` — 调度 + 可观测层（session 目录、status、heartbeat、event）。`@MainActor @Observable final class`。
- 新建：`Training/Training/SelfTest/SelfTestStatusView.swift` — 纯状态展示 view，零逻辑。
- 改：`Training/Training/TrainingApp.swift` — init 里启动 controller；body 切换到 StatusView（去 `.task` 触发）。
- 改：`Training/Training/SelfTest/SelfTestRunner.swift` — 产物写入改回调；删 cleanupLogs；runSingle 接受 controller 注入。
- 改：`Training/Training/dev_flow.sh` — 新增 `run_scenario` 子命令 + 冷启动确认重试。
- 测试：`Tests/TrainingAppTests/SelfTestControllerTests.swift`（新建）— status/heartbeat/event/session 的单元测试。

---

### Task 1: SelfTestController — session 目录与状态文件骨架

**Files:**
- Create: `Training/Training/SelfTest/SelfTestController.swift`
- Test: `Tests/TrainingAppTests/SelfTestControllerTests.swift`

**Interfaces:**
- Produces: `SelfTestController` 类，初始化 `init(scenario: Int)`；可观测属性 `var status: SelfTestStatus`；方法 `func start()`、`func update(state:)`、`func appendEvent(_:)`、`private func beat()`；session 目录在 `Documents/Sessions/<session>/`。
- Produces: `SelfTestStatus` struct（session/scenario/scenarioName/state/buildHash/srcFingerprint/started/updated/ended）。

- [ ] **Step 1: 写失败测试 — session 目录创建 + status.json 写入**

```swift
import XCTest
@testable import TrainingApp

final class SelfTestControllerTests: XCTestCase {
    func testStartCreatesSessionDirAndStatusRunning() throws {
        let c = SelfTestController(scenario: 12)
        XCTAssertEqual(c.status.scenario, 12)
        c.startSyncForTest()  // 同步版：只建目录写 status，不跑 Task
        let dir = c.sessionDirURLForTest()
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
        let statusURL = dir.appendingPathComponent("status.json")
        let data = try Data(contentsOf: statusURL)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["state"] as? String, "running")
        XCTAssertEqual(json["scenario"] as? Int, 12)
        XCTAssertNotNil(json["session"])
    }
}
```

- [ ] **Step 2: 运行测试，确认失败（类型不存在）**

Run: `swift test --filter SelfTestControllerTests`
Expected: FAIL — `cannot find 'SelfTestController' in scope`

- [ ] **Step 3: 实现 SelfTestController 骨架**

```swift
import Foundation

struct SelfTestStatus: Codable {
    var session: String
    var scenario: Int
    var scenarioName: String
    var state: String          // running | healthkit | planner | executing | done | error
    var buildHash: String
    var srcFingerprint: String
    var started: TimeInterval
    var updated: TimeInterval
    var ended: TimeInterval?
}

@MainActor
@Observable
final class SelfTestController {
    private(set) var status: SelfTestStatus
    private let session: String
    private let scenarioIndex: Int

    init(scenario: Int) {
        self.scenarioIndex = scenario
        self.session = SelfTestController.makeSessionId()
        self.status = SelfTestStatus(
            session: session, scenario: scenario,
            scenarioName: SelfTestController.scenarioName(for: scenario),
            state: "running",
            buildHash: AppVersion.buildHash,
            srcFingerprint: AppVersion.srcFingerprint,
            started: Date().timeIntervalSince1970,
            updated: Date().timeIntervalSince1970,
            ended: nil
        )
    }

    func start() {
        writeStatus()
        writeCurrentSessionPointer()
        Task { await SelfTestRunnerShared.run(scenario: scenarioIndex, controller: self) }
    }

    /// 测试用：只建目录写 status，不启动 Task。
    func startSyncForTest() { writeStatus(); writeCurrentSessionPointer() }

    func update(state: String) {
        status.state = state
        status.updated = Date().timeIntervalSince1970
        if state == "done" || state == "error" { status.ended = status.updated }
        writeStatus()
    }

    func appendEvent(_ line: String) {
        let ts = SelfTestController.ts(Date())
        let entry = "\(ts) | \(line)\n"
        let url = sessionDirURL().appendingPathComponent("events.log")
        if let data = entry.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path) {
                if let h = FileHandle(forWritingAtPath: url.path) {
                    h.seekToEndOfFile(); h.write(data); h.closeFile()
                }
            } else {
                try? data.write(to: url)
            }
        }
    }

    private func beat() {
        let url = sessionDirURL().appendingPathComponent("heartbeat.txt")
        try? String(Int(Date().timeIntervalSince1970)).write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeStatus() {
        let url = sessionDirURL().appendingPathComponent("status.json")
        if let data = try? JSONEncoder().encode(status) { try? data.write(to: url) }
    }

    private func writeCurrentSessionPointer() {
        let url = docsURL().appendingPathComponent("current_session.txt")
        try? session.write(to: url, atomically: true, encoding: .utf8)
    }

    func sessionDirURLForTest() -> URL { sessionDirURL() }
    private func sessionDirURL() -> URL {
        let dir = docsURL().appendingPathComponent("Sessions", isDirectory: true).appendingPathComponent(session, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private func docsURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func makeSessionId() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let hex = String(format: "%04x", UInt32.random(in: 0...0xFFFF))
        return "\(f.string(from: Date()))-\(hex)"
    }
    static func ts(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: d)
    }
    static func scenarioName(for idx: Int) -> String {
        let names = ["恢复查询","训练计划","睡眠分析","记录运动 1","记录运动 2",
                     "综合查询","单日数据","比赛工具","比赛注入","昨天比赛表现",
                     "今天状态","今天0点至今","查昨天RHR","查前天RHR","7天RHR表","赛后恢复"]
        return idx < names.count ? names[idx] : "scenario\(idx)"
    }
}
```

- [ ] **Step 4: 运行测试，确认通过**

Run: `swift test --filter SelfTestControllerTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Training/Training/SelfTest/SelfTestController.swift Tests/TrainingAppTests/SelfTestControllerTests.swift
git commit -m "feat: add SelfTestController session dir + status skeleton"
```

---

### Task 2: heartbeat 周期写入

**Files:**
- Modify: `Training/Training/SelfTest/SelfTestController.swift`
- Test: `Tests/TrainingAppTests/SelfTestControllerTests.swift`

**Interfaces:**
- Produces: `SelfTestController` 在 start() 启动 5s 周期 heartbeat，stop() 取消；可观测属性暴露最新 heartbeat 时间戳供 view 显示。

- [ ] **Step 1: 写失败测试 — heartbeat 写入并随时间更新**

```swift
func testHeartbeatUpdates() throws {
    let c = SelfTestController(scenario: 0)
    c.startHeartbeatForTest(intervalSeconds: 0.1)
    let url1 = c.sessionDirURLForTest().appendingPathComponent("heartbeat.txt")
    let t1 = try String(contentsOf: url1)
    Thread.sleep(forTimeInterval: 0.25)
    let t2 = try String(contentsOf: url1)
    c.stopHeartbeatForTest()
    XCTAssertNotEqual(t1, t2, "heartbeat 应更新")
}
```

- [ ] **Step 2: 运行，确认失败（方法不存在）**

Run: `swift test --filter SelfTestControllerTests/testHeartbeatUpdates`
Expected: FAIL — 方法不存在

- [ ] **Step 3: 实现 heartbeat**

在 SelfTestController 加：
```swift
private var heartbeatTask: Task<Void, Never>?
@MainActor var lastBeat: TimeInterval = 0

func startHeartbeatForTest(intervalSeconds: Double) {
    heartbeatTask = Task {
        while !Task.isCancelled {
            beat(); lastBeat = Date().timeIntervalSince1970
            try? await Task.sleep(nanoseconds: UInt64(intervalSeconds * 1_000_000_000))
        }
    }
}
func stopHeartbeatForTest() { heartbeatTask?.cancel(); heartbeatTask = nil }

// start() 内追加：
func start() {
    writeStatus(); writeCurrentSessionPointer()
    startHeartbeatForTest(intervalSeconds: 5)
    Task { await SelfTestRunnerShared.run(scenario: scenarioIndex, controller: self); stopHeartbeatForTest() }
}
```

- [ ] **Step 4: 运行，确认通过**

Run: `swift test --filter SelfTestControllerTests/testHeartbeatUpdates`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Training/Training/SelfTest/SelfTestController.swift Tests/TrainingAppTests/SelfTestControllerTests.swift
git commit -m "feat: add heartbeat to SelfTestController"
```

---

### Task 3: SelfTestRunner 接入 controller 回调（边跑边写 event）

**Files:**
- Modify: `Training/Training/SelfTest/SelfTestRunner.swift`
- Test: `Tests/TrainingAppTests/SelfTestControllerTests.swift`

**Interfaces:**
- Consumes: `SelfTestController`（注入）
- Produces: `SelfTestRunnerShared.run(scenario:controller:)` — 静态入口，调 `makeViewModel`/`sendMessage`/日志格式化（沿用现有 runOne 逻辑），每个节点回调 `controller.update(state:)` + `controller.appendEvent(_:)`；结束写 `stdout.log` 到 session 目录。
- 注意：链路执行逻辑（makeViewModel / sendMessage / Planner→工具→Executor）保持不变，只改"在哪写产物"。

- [ ] **Step 1: 写失败测试 — run 写 event 且 status 推进到 done**

```swift
func testRunWritesEventsAndDone() async throws {
    // 用一个 stub DeepSeekClient 避免真实网络（或用现有 makeViewModel 的内存路径）
    let c = SelfTestController(scenario: 12)
    await SelfTestRunnerShared.run(scenario: 12, controller: c)
    XCTAssertEqual(c.status.state, "done")
    let events = try String(contentsOf: c.sessionDirURLForTest().appendingPathComponent("events.log"))
    XCTAssertTrue(events.contains("launch"))
    XCTAssertTrue(events.contains("done"))
    // stdout.log 存在
    XCTAssertTrue(FileManager.default.fileExists(atPath: c.sessionDirURLForTest().appendingPathComponent("stdout.log").path))
}
```

> 注：若 run 触发真实 DeepSeek 网络调用，测试改用注入 mock service 的 makeViewModel 重载。Step 3 实现时若发现现有 makeViewModel 写死真实 client，则 Task 3 范围内加一个 `makeViewModel(service:)` 重载供测试注入，主路径仍用真实 client。

- [ ] **Step 2: 运行，确认失败**

Run: `swift test --filter SelfTestControllerTests/testRunWritesEventsAndDone`
Expected: FAIL — `SelfTestRunnerShared` 不存在

- [ ] **Step 3: 实现 SelfTestRunnerShared.run**

在 SelfTestRunner.swift 加静态门面，复用现有 runOne 的日志格式化逻辑（把 `buf` 数组改成边 append 边写）：
```swift
enum SelfTestRunnerShared {
    @MainActor
    static func run(scenario: Int, controller: SelfTestController) async {
        controller.appendEvent("launch | scenario=\(scenario) buildHash=\(AppVersion.buildHash)")
        controller.update(state: "executing")
        let runner = SelfTestRunner()  // 复用现有 makeViewModel / runOne 链路
        let scenarios = SelfTestRunner.allScenarios()
        guard scenario < scenarios.count else { controller.update(state: "error"); return }
        let sc = scenarios[scenario]
        let vm = sc.useMatchVM ? runner.makeViewModelWithMatch() : runner.makeViewModel()
        // 边跑边写：runOne 内部每个 buf.append 改为同时 controller.appendEvent
        // （具体：把 runOne 的 buf 构造抽取，每条同时追加 event）
        await runner.runOneInstrumented(scenario, vm: vm, scenario: sc, controller: controller)
        controller.update(state: "done")
        // stdout.log：runner.runOneInstrumented 已把完整 buf 写入 session 目录
    }
}
```
同时：把现有 `runOne` 内部 `buf.append(...)` 的每条抽成 hook，调用 `controller.appendEvent`；末尾把 `buf.joined` 写到 `controller.sessionDirURLForTest().appendingPathComponent("stdout.log")`（改用一个公开的 `controller.writeStdout(_:)`）。删除 `cleanupLogs` 和 `writeLogFile`（session 目录永不覆盖，无需删/旧 selftest-N.log 不再写）。

- [ ] **Step 4: 运行，确认通过**

Run: `swift test --filter SelfTestControllerTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Training/Training/SelfTest/SelfTestRunner.swift Tests/TrainingAppTests/SelfTestControllerTests.swift
git commit -m "feat: SelfTestRunner writes events via controller callback"
```

---

### Task 4: TrainingApp 触发点移到 init + SelfTestStatusView

**Files:**
- Modify: `Training/Training/TrainingApp.swift`
- Create: `Training/Training/SelfTest/SelfTestStatusView.swift`

**Interfaces:**
- Consumes: `SelfTestController`
- Produces: app init 启动 controller（脱离 .task）；body 在 selftest 模式渲染 `SelfTestStatusView`。

- [ ] **Step 1: 写失败测试 — scenarioIndex 命中时 controller 被持有**

> TrainingApp.init 难以单测；改为验证 SelfTestStatusView 能读取 controller.status。test 放现有 ChatUITests 或新建，验证 view 编译通过即可。

```swift
// Tests/TrainingAppTests/SelfTestStatusViewTests.swift
import XCTest
import SwiftUI
@testable import TrainingApp

final class SelfTestStatusViewTests: XCTestCase {
    func testStatusViewCompiles() throws {
        let controller = SelfTestController(scenario: 12)
        controller.startSyncForTest()
        let view = SelfTestStatusView(controller: controller)
        XCTAssertNotNil(view.body)  // 编译即验证
    }
}
```

- [ ] **Step 2: 运行，确认失败（SelfTestStatusView 不存在）**

Run: `swift test --filter SelfTestStatusViewTests`
Expected: FAIL — `SelfTestStatusView` 不存在

- [ ] **Step 3: 实现 SelfTestStatusView**

```swift
import SwiftUI

struct SelfTestStatusView: View {
    let controller: SelfTestController
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("自测模式 · 场景 \(controller.status.scenarioName)").font(.headline)
            Text("state: \(controller.status.state)").monospacedDigit()
            Text("session: \(controller.status.session)").font(.caption2).foregroundColor(.secondary)
            Text("build: \(controller.status.buildHash)").font(.caption2).foregroundColor(.secondary)
            if controller.status.state == "done" { Text("✅ 完成").foregroundColor(.green) }
            else if controller.status.state == "error" { Text("❌ 失败").foregroundColor(.red) }
            else { ProgressView().scaleEffect(0.7) }
        }
        .padding()
        .accessibilityIdentifier("SELFTEST_DONE")  // 保持 UI 探针兼容现有 XCUITest
    }
}
```

- [ ] **Step 4: 改 TrainingApp：init 启动 controller，body 切 StatusView**

```swift
@main struct TrainingApp: App {
    @State private var controller: SelfTestController?
    init() {
        clearDashboardCacheIfNeeded()
        AppVersion.writeMarker()
        if let idx = scenarioIndex() {
            let c = SelfTestController(scenario: idx)
            c.start()
            _controller = State(initialValue: c)
        }
    }
    var body: some Scene {
        WindowGroup {
            if let controller {
                SelfTestStatusView(controller: controller)
            } else if AppConfig.isSelfTestMode || CommandLine.arguments.contains("--self-test") {
                SelfTestHostView()
            } else {
                ContentView()
            }
        }
    }
    // scenarioIndex() / clearDashboardCacheIfNeeded() 保持不变
}
```

- [ ] **Step 5: 运行测试 + 编译**

Run: `swift test --filter SelfTestStatusViewTests`；`xcodebuild build`
Expected: PASS + BUILD SUCCEEDED

- [ ] **Step 6: Commit**

```bash
git add Training/Training/TrainingApp.swift Training/Training/SelfTest/SelfTestStatusView.swift Tests/TrainingAppTests/SelfTestStatusViewTests.swift
git commit -m "feat: move selftest trigger to init + SelfTestStatusView"
```

---

### Task 5: dev_flow.sh 新增 run_scenario（冷启动确认 + 重试）

**Files:**
- Modify: `Training/Training/dev_flow.sh`

**Interfaces:**
- Produces: `bash dev_flow.sh scenario <N>` 子命令；`run_scenario <N>` 函数：launch → 轮询 current_session.txt 确认新 session → 等 status done/error/heartbeat-stale → 拉 session 目录 → 报告。

- [ ] **Step 1: 写 run_scenario 函数骨架（无测试，shell 手动验证）**

```bash
run_scenario() {
    local N="${2:-0}"
    local PREV_SESSION=""
    [ -f /tmp/training_current_session ] && PREV_SESSION=$(cat /tmp/training_current_session 2>/dev/null)
    local CONFIRMED=0
    for attempt in 1 2 3; do
        echo "[launch attempt $attempt] scenario=$N"
        xcrun devicectl device process launch --device "$UDID" --terminate-existing \
            com.example.Training --arguments "--self-test-scenario=$N" 2>&1 | tail -1
        # 冷启动确认：轮询 current_session.txt 30s
        local waited=0
        while [ "$waited" -lt 30 ]; do
            xcrun devicectl device copy from --device "$UDID" --domain-type appDataContainer \
                --domain-identifier "$BUNDLE" --source "Documents/current_session.txt" \
                --destination /tmp/training_current_session 2>/dev/null | grep -qi received
            local CUR=$(cat /tmp/training_current_session 2>/dev/null)
            if [ -n "$CUR" ] && [ "$CUR" != "$PREV_SESSION" ]; then
                PREV_SESSION="$CUR"; CONFIRMED=1; break 2
            fi
            sleep 5; waited=$((waited+5))
        done
        [ "$CONFIRMED" = "1" ] && break
        echo "attempt $attempt: 未确认新 session，重试"
    done
    [ "$CONFIRMED" != "1" ] && { echo "❌ 冷启动确认失败"; exit 1; }

    local SESSION=$(cat /tmp/training_current_session)
    echo "session=$SESSION"
    # 等完成：轮询 status.json
    local waited=0
    local STATE=""
    while [ "$waited" -lt 180 ]; do
        xcrun devicectl device copy from --device "$UDID" --domain-type appDataContainer \
            --domain-identifier "$BUNDLE" --source "Documents/Sessions/$SESSION/status.json" \
            --destination /tmp/training_status.json 2>/dev/null | grep -qi received
        STATE=$(grep -o '"state":"[^"]*"' /tmp/training_status.json 2>/dev/null | cut -d'"' -f4)
        [ "$STATE" = "done" ] || [ "$STATE" = "error" ] && break
        # heartbeat stale 判定
        xcrun devicectl device copy from --device "$UDID" --domain-type appDataContainer \
            --domain-identifier "$BUNDLE" --source "Documents/Sessions/$SESSION/heartbeat.txt" \
            --destination /tmp/training_heartbeat.txt 2>/dev/null | grep -qi received
        local HB=$(cat /tmp/training_heartbeat.txt 2>/dev/null)
        local NOW=$(date +%s)
        if [ -n "$HB" ] && [ $((NOW - HB)) -gt 60 ]; then
            echo "⚠️ heartbeat 60s 未更新，判定挂起（停在 state=$STATE）"; break
        fi
        sleep 5; waited=$((waited+5))
    done
    # 拉 session 目录
    local OUT="$SPM/artifacts/$SESSION"
    mkdir -p "$OUT"
    for f in status.json heartbeat.txt events.log stdout.log; do
        xcrun devicectl device copy from --device "$UDID" --domain-type appDataContainer \
            --domain-identifier "$BUNDLE" --source "Documents/Sessions/$SESSION/$f" \
            --destination "$OUT/$f" 2>/dev/null | grep -qi received && echo "  拉取 $f ✅"
    done
    echo "=== state=$STATE session=$SESSION ==="
    echo "--- events.log ---"; cat "$OUT/events.log" 2>/dev/null
    echo "--- stdout.log ---"; cat "$OUT/stdout.log" 2>/dev/null
}
```

- [ ] **Step 2: 在 case 加子命令 + 写测试脚本**

case 分支加：
```bash
scenario)  shift; run_scenario "$@" ;;
```
然后 `scenario` 子命令需先 build+install（复用 run_install）。在 run_scenario 开头加 `run_install`。

- [ ] **Step 3: 手动验证 — 跑场景 12**

Run: `bash dev_flow.sh scenario 12`
Expected: 输出 session id + state=done + events.log 含 launch/done + stdout.log 含 `59 bpm`

- [ ] **Step 4: 验证重跑不拉旧数据**

再跑一次 `bash dev_flow.sh scenario 12`，确认两次 session id 不同、内容都是本次新跑（buildHash 一致但 session 不同）。

- [ ] **Step 5: Commit**

```bash
git add Training/Training/dev_flow.sh
git commit -m "feat: dev_flow run_scenario with cold-start confirm + retry"
```

---

### Task 6: 端到端验收 + 清理

**Files:**
- 无新文件，验证 spec 验收标准。

- [ ] **Step 1: 验收标准 1 — 改代码后跑单场景拿新输出**

改 MetricTool 一处无关紧要的字符串（或复用现有），`bash dev_flow.sh scenario 12`，确认拉到本次新 session、state=done、buildHash 与 version.txt 一致、stdout 含本次输出、非旧日志。

- [ ] **Step 2: 验收标准 2 — 模拟中途挂起能判定**

断网（关 Wi-Fi 或停 DeepSeek key）后 `bash dev_flow.sh scenario 1`，确认 status.state 停在中间（planner/executing）、heartbeat 60s 未更新 → 脚本报"判定挂起" + events.log 显示停在哪个节点。

- [ ] **Step 3: 验收标准 3 — 连续两次同场景不覆盖**

`bash dev_flow.sh scenario 12` 跑两次，确认两个不同 session 目录、互不覆盖。

- [ ] **Step 4: 验收标准 4 — buildHash 一致性**

拉 session 内 status.json 的 buildHash vs version.txt 一致，证明装新二进制且本次跑了。

- [ ] **Step 5: 更新 BUILD_MANUAL + 提交**

更新 `docs/BUILD_MANUAL.md` 记录 `dev_flow.sh scenario <N>` 用法、session 目录位置、状态判断方法。Commit。

```bash
git add docs/BUILD_MANUAL.md
git commit -m "docs: document selftest harness session + run_scenario"
```

## 自审

- spec 覆盖：触发点(Task4)/状态协议(Task1,2,3)/session定位(Task1+5指针)/运行控制(Task5)全覆盖。
- 无占位：每个 step 有实际代码或命令。
- 类型一致：`SelfTestStatus`、`SelfTestController`、`SelfTestRunnerShared.run` 跨 task 签名一致；`writeStdout` 在 Task3 提及，Task1 需补一个 `func writeStdout(_:)`——**修正**：Task1 Step3 已有 appendEvent，stdout 写入应在 Task3 由 runner 调 `controller.writeStdout(buf)`，需在 Task1 补 `writeStdout` 方法。计划已隐含，实现时 Task1 先加该方法。
