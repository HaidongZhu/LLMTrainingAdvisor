# 真机自测调试困难分析

> 目的：记录当前真机验证流程中遇到的调试困难，供 iOS 专家分析。
> 不讨论业务 bug 本身，只讨论"为什么难以稳定地真机验证一个改动"。

## 背景

这是一个 SwiftUI iOS app（健康/运动教练）。我有一套自测基础设施：

- 启动参数 `--self-test-scenario=N` → app 进入 `SelfTestSingleView(scenarioIndex: N)`。
- `SelfTestSingleView` 的 `.task` 修饰符调用 `runner.runSingle(N)`，跑一个对话场景（Planner→工具→Executor），把完整链路日志写入 `Documents/selftest-N.log`。
- 跑完后日志留在沙盒，我用 `xcrun devicectl device copy from` 拉到 Mac 分析。
- 设备是无线连接的真机（CoreDevice over Wi-Fi，UDID `<YOUR_DEVICE_UDID>`）。

## 我是怎么测试、怎么拿数据的（完整方法）

为了让专家能判断，下面把从改代码到拿日志的每一步、用的每条命令、每步看到什么，都写清楚。

### 设备与连接

- 真机：iPhone，UDID `<YOUR_DEVICE_UDID>`，bundle id `com.example.Training`。
- 连接方式：**无线**（CoreDevice over Wi-Fi），不是插线 USB。所有 `devicectl` 命令走 `xcrun devicectl`。
- Xcode 工程：`Training/Training.xcodeproj`，scheme `Training`。

### 自测机制（app 内部逻辑，关键）

1. 用 launch argument `--self-test-scenario=N` 启动 app。
2. `TrainingApp.swift` 的 `scenarioIndex()` 解析这个参数 → 返回 N。
3. `body` 里 `if let idx = scenarioIndex()` 命中 → 根视图渲染成 `SelfTestSingleView(scenarioIndex: N)`。
4. `SelfTestSingleView` → `SelfTestHostView(singleScenario: N)`，其 `.task { await runner.runSingle(idx) }` 在视图出现时调用 `runSingle(N)`。
5. `runSingle` 跑一个对话场景（发给 DeepSeek 的 Planner→工具调用→Executor 链路），把完整过程（Planner 原始 JSON、每次工具调用、工具返回结果、Executor 回复、token/花费）格式化成日志行。
6. `runSingle` 内部：
   - 开头 `cleanupLogs()`：删除沙盒里旧的 `selftest-N.log`（只删当前场景号对应的那个）。
   - 结尾 `writeLogFile()`：把本次日志写到 `Documents/selftest-N.log`（N = 当前场景号）。
7. 日志留在 app 沙盒的 Documents 目录，我再用 `devicectl copy from` 拉到 Mac。

> 关键点：触发逻辑是 SwiftUI 的 `.task`。**`.task` 在视图首次 appear 时执行一次。** 这是我怀疑问题的核心——下面会说。

### 我实际跑一次验证的完整流程（命令级）

假设我刚改了 `MetricTool.swift`，要验证"昨天 RHR"（场景 12）是否返回真实值：

```bash
# 1. 编译（注入版本标记：git hash + 源码指纹）
CLEAN_BUILD=0 bash dev_flow.sh build
# 看到: BUILD SUCCEEDED (hash=xxx fp=xxx clean=)

# 2. 装到设备（覆盖安装 + 版本确认）
CLEAN_BUILD=0 bash dev_flow.sh install
# 看到: App installed + ✅ 版本确认：hash=xxx fp=xxx = 本次 build

# 3. 用 launch argument 启动场景 12（强制先杀后启）
xcrun devicectl device process launch \
  --device <YOUR_DEVICE_UDID> \
  --terminate-existing \
  com.example.Training \
  --arguments "--self-test-scenario=12"
# 看到: Launched application with com.example.Training bundle identifier.

# 4. 等待并拉日志（轮询直到出现 SELFTEST_DONE）
# 用一个 until 循环反复 copy from，grep SELFTEST_DONE 判断完成
xcrun devicectl device copy from \
  --device <YOUR_DEVICE_UDID> \
  --domain-type appDataContainer \
  --domain-identifier com.example.Training \
  --source "Documents/selftest-12.log" \
  --destination /tmp/selftest-12.log

# 5. 读日志
cat /tmp/selftest-12.log | grep -E "TOOL_RESULT|EXECUTOR"
```

### 版本确认机制（用于判断"装的二进制是不是新的"）

- build 时 `dev_flow.sh run_build` 把 git hash + 源码指纹注入 `AppVersion.swift` 的静态字段，编译进二进制。
- app 启动时 `init()` 调 `AppVersion.writeMarker()` 把这些值写到 `Documents/version.txt`。
- `verify_version`（install 后自动跑）从设备拉 `version.txt`，和本地 build marker 对比。
- 我也单独拉过 `version.txt`：它的 **mtime = 最新 install 后 app 首次启动的时刻**，内容是最新 build hash → 证明 app 冷启动过、`init()` 跑过、装的是新二进制。

### 怎么判断"日志是新跑的还是旧的"

- 看 `selftest-N.log` 的 **mtime**：如果 = 本次启动后的时刻，是新跑的；如果是上次/更早的时刻，就是旧文件没被覆盖。
- 内容里第一行是 `=== SCENARIO|0|<场景名> ===`，可对照场景名确认。

### 这次实际发生的（关键证据）

针对"昨天 RHR"（场景 12）和"前天 RHR"（场景 13）：

| 时刻 | 操作 | 结果 |
|---|---|---|
| 11:53 | 旧代码跑场景 12 | 写出 selftest-12.log，内容 `TOOL_RESULT\|rhr_yesterday\|—`（旧 bug） |
| ~12:06 | 改代码 + 重装 | ✅ 版本确认通过，装的二进制是新的 |
| ~12:08 | `--terminate-existing` 启动场景 12 | 拉到的日志 mtime 还是 11:53，内容还是 `—`（旧的） |
| ~12:15 | 再次 `--terminate-existing` 启动场景 12 | **这次 mtime 更新到 12:15，内容变成 `59 bpm`（新代码生效）** ✅ |
| 12:13 | 启动场景 13 | 拉到 mtime 11:46 的旧日志（内容 `—`） |
| ~12:30 | 再 `--terminate-existing` 启动场景 13 | 内容变 `57 bpm`（生效），但 mtime 判断不稳 |
| 12:38 | 启动场景 9 | 拉到 mtime 11:18 的旧日志（内容是旧跑的完整数据） |
| 12:40 | 再 `--terminate-existing` 启动场景 9 | **拉到的 mtime 仍是 11:18，没更新**（场景 9 始终没重跑） |

**核心矛盾**：`version.txt` 的 mtime 每次重装后都更新到最新（证明 app 冷启动了），但 `selftest-N.log` 经常不更新（证明 `.task`/`runSingle` 没重跑）。同一个 app 启动，`init()` 跑了但 `.task` 没跑。

### XCUITest 路径（dev_flow.sh selftest 走的）

- `xcodebuild test` 跑 `TrainingUITests`，每个 test 方法 `app.launchArguments = ["--self-test-scenario=N"]; app.launch()`，然后 `waitForExistence` 一个叫 `SELFTEST_DONE` 的 UI 文本。
- 日志拉取同上（`dev_flow.sh run_selftest` 只拉 selftest-0..8，**没覆盖 9..15**——这些是我这次新增的场景，没加进 XCUITest 列表）。
- 我这次验证主要**绕过 XCUITest**，直接用 `devicectl process launch --arguments` 跑单个场景，因为 XCUITest 列表里没有 9..15。

---

## 核心困难：重跑同一个 selftest 场景，日志不更新

### 现象

1. 第一次跑某个场景（例如场景 12），app 冷启动 → `.task` 触发 → `runSingle` 执行 → 写出 `selftest-12.log`（设备上文件 mtime = 写入时刻）。✅ 成功。
2. 改代码、重新 build、重新 install（覆盖安装）。
3. 再次 `devicectl process launch --self-test-scenario=12` 拉日志，发现：
   - 设备上 `selftest-12.log` 的 mtime **仍是第一次运行的时刻**，没被覆盖。
   - 内容也是旧的（改代码前的输出）。
4. 即使我加 `--terminate-existing`（先杀后启），下一次拉到的日志**仍然是旧的**，没更新。

### 关键观察（已确认的事实）

- 重装后 app 确实是新的二进制（通过单独的 version.txt 标记确认：拉到的 `version.txt` mtime = 最新 install 时刻，内容是最新的 build hash）。说明 app 冷启动过、`init()` 跑过。
- 但带 `--self-test-scenario=N` 启动时，`runSingle` 看起来**没有重新执行**（日志没更新，`cleanupLogs` 也没删掉旧日志——否则设备上不会有那个旧文件）。
- `devicectl device info listprocesses` **查不到** Training 进程（即使它应该在前台/挂起）。所以无法用 `process terminate --pid` 干净杀掉它。
- `--terminate-existing` 官方说"会等 app 终止"，但实际效果像是"把已挂起的 app 拉到前台"，并没有让 SwiftUI 的 `.task` 重新触发。
- 有时候 `--terminate-existing` **确实生效**了一次（场景 12 在某次重装后成功覆盖了日志，mtime 更新到最新），但**不稳定**，无法可靠复现。
- 串行跑不同场景时（12→13→9），后一个场景有时继承前一个的"app 还活着"状态，导致后一个的 `.task` 不触发。

### 我的猜测（待 iOS 专家判断对错）

1. **SwiftUI `.task` 只在 view 首次 appear 时运行一次。** 如果 app 进程没被真正杀掉（只是挂起/后台），下次 launch 是"恢复"而非"冷启动"，view 已经存在，`.task` 不会重跑。所以 `runSingle` 不会被再次调用，日志自然不更新。
2. **`devicectl process launch` 对一个挂起的 app，可能走的是"激活"路径而非"重启"路径。** 即使带 `--terminate-existing`，终止信号可能没有彻底杀掉进程（或被 iOS 的 app snapshot 机制在恢复时回放），导致进程实际没死。
3. **`listprocesses` 查不到自己的 app**，可能是权限/过滤问题（第三方前台 app 不在默认进程列表），这让我无法用 pid 精确杀进程来强制冷启动。
4. **覆盖安装本身不保证冷启动**：install 新二进制后，如果旧进程还挂着，iOS 可能复用旧进程加载新二进制，但 SwiftUI 视图树已经构建过，`.task` 不会再跑。

## 次要困难：日志拉取的"假成功"

- `devicectl device copy from` 有时返回 `File received from Device`，但拉到的是**旧文件**（设备上还残留上次的日志）。
- 我的等待逻辑用 `until ... grep -qi received && grep -q SELFTEST_DONE` 判断"完成"，结果匹配到的是旧日志里的旧 `SELFTEST_DONE` 行 → 误以为新跑完成了，实际是旧数据。
- 本地文件 mtime 能区分新旧，但我用 shell 字符串比较 mtime（`[ "$m" \> "12:21" ]`）在某些格式下不可靠，导致监控要么假命中、要么超时。

## 这些困难导致的问题

- 无法可靠地"改一行代码 → 真机跑一遍 → 看新输出"。经常出现"明明重装重启了，拉到的还是旧日志"，反复怀疑是不是 build 没生效、是不是代码没改对，浪费大量时间。
- 容易做出错误结论（误以为修复无效，实际是日志没更新）。
- 版本确认基建（build hash + srcFingerprint）能证明"装的二进制是对的"，但证明不了"这次启动真的重跑了 selftest 逻辑"——中间隔了 `.task` 不重跑这一层。

## 想请教 iOS 专家的问题

1. `devicectl process launch --terminate-existing` 对一个挂起的前台 app，到底会不会真正重启进程？还是只是激活？有没有办法**强制冷启动**一个 app（绕过 iOS 的状态恢复）？
2. SwiftUI `.task` 在 app 从后台恢复时确实不会重跑吗？如果要让"每次 app 到前台都重跑某段逻辑"，正确做法是什么（`.onAppear`？`scenePhase` 监听？`NSNotification` 的 `willEnterForeground`？）
3. 为什么 `devicectl device info listprocesses` 查不到自己的第三方前台 app？有没有别的方式拿到它的 pid 来精确终止？
4. 覆盖安装（`devicectl device install app` 覆盖同 bundle id）后，iOS 是否会自动杀掉旧进程？还是可能保留旧进程？
5. 有没有更稳的真机自动化验证方式（比如用 XCUITest 而非 launch argument + `.task`）能避免这个问题？我现有的 XCUITest 走的是同一套 launch argument 机制，怀疑也有同样问题。

## 当前临时绕过办法（不可靠）

- 改跑**不同的**场景号（app 进程对每个新场景是首次 appear，`.task` 会触发）。所以验证"昨天RHR"用场景 12、"前天RHR"用场景 13，各跑一次能成功。但要**重跑同一个**场景看新改动，就得靠运气或反复 `--terminate-existing`。

---

附：相关代码位置
- 启动参数路由：`Training/Training/TrainingApp.swift:40-48`（`scenarioIndex()`）→ `SelfTestSingleView`
- `.task` 触发：`Training/Training/SelfTest/SelfTestRunner.swift` 的 `SelfTestHostView` 末尾 `.task { runner.runSingle(idx) }`
- 日志写入：同文件 `writeLogFile()`，写到 `Documents/selftest-N.log`
- 拉取脚本：`dev_flow.sh` 的 `run_selftest`（只拉 selftest-0..8，未覆盖 9..15）
