# 真机单场景可重复 Test Harness 设计

> 范围：让"改代码 → 真机跑单场景 → 稳定看到新输出"循环 100% 可靠，不靠猜。
> 批量回归、流式日志、Mac 编排器平台化为后续延伸，本期不做。

## 问题（背景见 docs/DEBUG_DIFFICULTY.md）

当前真机验证依赖 SwiftUI `.task` 触发 selftest，导致：

1. **运行控制不可靠**：app 进程挂着时，`--terminate-existing` 重启不保证 `.task` 重跑 → 重跑同场景经常拉到旧日志。
2. **状态黑盒**：不知道 runSingle 跑没跑、跑到哪、是否异常 → copy log 全靠猜，旧 log 的旧 `SELFTEST_DONE` 行造成假命中。
3. **产物覆盖**：`selftest-N.log` 覆盖写 + 末尾才 write → 中途崩则啥都没有，且无法区分"没启动/中途挂/正常完成"。
4. **UI 与 Test 耦合**：Runner 挂在 view 的 `.task` 上，生命周期由 view 摆布。

核心诊断：这不是 iOS bug，是缺一个可重复的 Test Harness——运行控制不可靠。`version.txt`（init 里写）每次重装都更新，证明 app 冷启动了；但 `selftest-N.log`（.task 里写）经常不更新——同一启动 init 跑了、.task 没跑，印证触发点是 view 生命周期问题。

## 设计目标

- app 一启动**必然**执行测试，不依赖任何 view 出现。
- Mac 侧能区分四种状态：**没启动 / 中途挂起 / 崩溃 / 正常完成**。
- 重跑同场景 100% 拿到本次新输出，不拉旧数据。
- 中途挂起时也能拿到已发生的中间过程（停在哪个 event）。

## 架构

```
Mac (dev_flow.sh)
  │  launch --terminate-existing --args "--self-test-scenario=N"
  │  冷启动确认：轮询 current_session.txt + status.json，N 秒内出现新 session
  │  未出现 → 重试（最多 3 次）
  │  等完成：轮询 status.json 直到 done/error，或 heartbeat 60s 不更新 → 判定挂起
  │  拉整个 session 目录
  ▼
App
  TrainingApp.init()  ← 触发点（脱离 view）
    └─ SelfTestController(scenario: N).start()
         ├─ 生成 session id，建目录，写 status.json(running) + current_session.txt
         ├─ 启动 heartbeat（每 5s）
         ├─ 调 SelfTestRunner（复用链路，边跑边写 event）
         │    每个关键节点 → 回调 controller 写 events.log + 更新 status.json
         └─ 结束写 status.json(done/error)
  SelfTestStatusView  ← 纯状态展示，不触发任何逻辑
```

**职责边界**：
- `SelfTestController`：调度 + 可观测（session 目录、status、heartbeat、event 写入）。不碰 Planner/工具/Executor 内部。
- `SelfTestRunner`：链路执行（makeViewModel、sendMessage、Planner→工具→Executor）**不变**。只改产物写入时机：从"末尾一次 writeLogFile"改成"关键节点边跑边回调 controller 写 event"。
- `SelfTestStatusView`：只读 status，显示进度，零逻辑。

## 触发点（脱离 view）

```swift
@main struct TrainingApp: App {
    init() {
        clearDashboardCacheIfNeeded()
        AppVersion.writeMarker()
        if let idx = scenarioIndex() {
            SelfTestController(scenario: idx).start()
        }
    }
    var body: some Scene {
        WindowGroup {
            if scenarioIndex() != nil {
                SelfTestStatusView()  // 纯展示，不触发逻辑
            } else { ContentView() }
        }
    }
}
```

- 执行逻辑从 `.task` 移到 `init()`，与 `version.txt` 同时机——已证明该路径可靠触发。
- `init()` 是同步上下文，`start()` 内部 `Task {}` 启动异步执行。**约定：测试期间 app 必须保持前台**（用户确认不会让 app 进后台），前台 `Task` 不冻结，单场景 5-30s 跑完。不加 `performExpiringActivity`，留作后续。

## 状态协议（status + heartbeat + event 全套）

每次启动生成一个 session，产物写进 `Documents/Sessions/<session>/`，**永不覆盖**：

```
Documents/
  current_session.txt          指针：内容 = 本次 session id（启动时立即写）
  Sessions/
    <session>/                 session id = 时间戳+短随机，如 20260710-121530-a3f2
      status.json              状态机
      heartbeat.txt            每 5s 覆盖写当前时间戳
      events.log               关键节点追加
      stdout.log               完整日志（原 selftest log 内容，结束时一次性写）
```

### status.json 状态机

```json
{
  "session": "20260710-121530-a3f2",
  "scenario": 12,
  "scenarioName": "查昨天RHR",
  "state": "running",          // running → healthkit → planner → executing → done | error
  "buildHash": "c633dbd",
  "srcFingerprint": "8d2221ac",
  "started": 1719999930,
  "updated": 1719999960,
  "ended": null
}
```

state 进每个阶段就覆盖更新 `updated`。结束写 `done`/`error` + `ended`。

### heartbeat.txt

每 5s 覆盖写当前时间戳（unix 秒）。作用：`state=running` 时，若 heartbeat 距当前 >60s → 判定挂起（前台 Task 被冻结/卡死）。

### events.log

每个关键节点追加一行（带时间戳）：

```
20260710-121530 | launch | scenario=12 buildHash=c633dbd
20260710-121531 | healthkit | ok
20260710-121533 | planner | tools=[get_metric days_ago=1 metric=rhr] template=...
20260710-121534 | tool_call | rhr_yesterday get_metric days_ago=1 metric=rhr
20260710-121535 | tool_result | rhr_yesterday | 59 bpm
20260710-121536 | executor | 根据数据...
20260710-121536 | done | in=4575 out=344 cost=0.005263 time=5.59s
```

**边跑边写**：Runner 在每个节点回调 controller 追加，不等结束。中途挂 → events.log 停在最后一个完成的节点 → 一眼看出挂在哪一步。

### stdout.log

原 `runOne` 格化的完整日志（PLANNER_RAW / TOOL / TOOL_RESULT / EXECUTOR / COST 等），结束时一次性写。正常完成才有；中途挂时靠 events.log 补中间过程。

## Session 定位（指针 + 列目录双保险）

Mac 侧定位本次 session：
1. 拉 `current_session.txt` 拿指针 → 拉 `Sessions/<指针>/`。
2. 指针失效（文件不存在/指向不存在的目录）→ 列 `Sessions/`，按目录名（时间戳前缀）取最新兜底。

永不覆盖旧 session → 杜绝"拉到旧文件假命中"。

## 运行控制（Mac 侧 dev_flow.sh）

新增 `run_scenario <N>` 子命令：

```bash
run_scenario(N):
  for attempt in 1..3:
    devicectl launch --terminate-existing --args "--self-test-scenario=N"
    # 冷启动确认：轮询 current_session.txt，session id 与上次不同 且 status.json 出现
    poll (5s 间隔, 最长 30s) until new_session_confirmed
    if confirmed: break
    else: echo "attempt $attempt: 未冷启动/未跑，重试"
  if not confirmed after 3: 报错退出

  # 等完成：轮询 status.json
  poll (5s 间隔, 最长 180s):
    state=done → 成功，break
    state=error → 失败，break
    heartbeat 距今 >60s 且 state!=done → 判定挂起，break（拉部分产物）

  # 拉整个 session 目录
  copy Sessions/<session>/ → 本地 artifacts/<session>/
  echo 报告：state + 关键 event + 成本
```

- 轮询 5s 间隔（copy 一次 ~3-4s，避免堆调用）。
- 冷启动确认靠"新 session id"判断，不靠文件 mtime 字符串比较（旧方案痛点）。

## 与现有自测的关系

- **保留** SelfTestRunner 的链路执行逻辑（makeViewModel / sendMessage / Planner→工具→Executor）。
- **改** Runner 产物写入：从末尾 `writeLogFile`（写 `selftest-N.log`）改成节点回调 controller 追加 `events.log` + 结束写 `stdout.log`。删除 `cleanupLogs`（session 目录永不覆盖，无需删旧）。
- **废弃** `.task { runSingle }` 触发，改 init+TestController。
- 现有 XCUITest（0..8）+ 新场景（9..15）统一走 `run_scenario`。

## 不做（本期范围外）

- 批量回归、流式日志（devicectl log streaming / HTTP server）、Mac 端 Test Orchestrator 平台化。
- `performExpiringActivity` 后台执行保障（靠"测试前台"约定）。
- 多设备并行。

## 验收标准

1. 改一行代码 → `run_scenario 12` → 必拉到本次新 session 的产物（status.state=done + 新 buildHash + 新输出），不出现旧日志。
2. 模拟中途挂起（如断网让 sendMessage 卡死）→ status.state 停在中间阶段 + heartbeat 不更新 → Mac 判定挂起 + events.log 显示停在哪个节点。
3. 连续跑同一场景两次 → 两个不同 session 目录，互不覆盖。
4. `version.txt` 与 session status 的 buildHash 一致，证明装的是新二进制且本次跑了。
