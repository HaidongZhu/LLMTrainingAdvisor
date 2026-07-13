# Training App — 测试 / 构建 / 安装 手册

## 前置条件

- macOS 15+，Xcode 16+（含 iOS 18 SDK）
- 已连接的 iPhone（UDID: `<YOUR_DEVICE_UDID>`）
- Swift 6.0 工具链

## 项目结构

```
Training/                     # 仓库根目录
├── Package.swift             # SPM 包定义（编译 Training/Training/ 下的文件）
├── Training/
│   ├── Training.xcodeproj/   # Xcode 项目
│   ├── Training/             # 源码（SPM 和 Xcode 共享同一份）
│   │   ├── *.swift           # 业务逻辑
│   │   └── Tools/            # AI 工具定义
│   ├── TrainingUITests/      # XCUITest（仅 Xcode 运行）
│   └── dev_flow.sh           # 开发流程脚本
└── Tests/TrainingAppTests/   # SPM 单元测试（swift test 运行）
```

## 一、运行单元测试

```bash
swift test
```

此命令：
1. 编译 `Package.swift` 中定义的 `TrainingApp` target（源码路径 = `Training/Training/`）
2. 编译并运行 `Tests/TrainingAppTests/` 下的所有单元测试
3. 所有测试使用内存 SQLite、Mock 网络 — 无需真机、无需网络

预期：113 tests passed, 0 failed。

## 二、Xcode 编译（构建 .app）

```bash
cd Training
xcodebuild -project Training.xcodeproj \
  -scheme Training \
  -destination "platform=iOS,id=<YOUR_DEVICE_UDID>" \
  -allowProvisioningUpdates \
  build 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)|error:"
```

如果输出 `BUILD SUCCEEDED`，编译成功。

> **注意**：`dev_flow.sh build` 仅编译，不跑测试。需要测试+编译用 `dev_flow.sh deploy`。

## 三、安装到真机

> ⚠️ **铁律：不论如何不能丢数据库数据。**
> `training.db` 在 App 沙盒 Documents/ 下。**卸载 App 会清空整个沙盒（含 DB 的比赛日程、活动记录）——禁止用卸载 App 的方式清缓存。**
> 清趋势/训练缓存只用 `--clear-dashboard-cache` launch argument（只删 UserDefaults 4 个 cache key，不碰 DB、不卸载）：
> ```bash
> xcrun devicectl device process launch --device <UDID> com.example.Training "--clear-dashboard-cache"
> ```
> App 启动时检测到该参数只清 dashboard_weekly_trend/dashboard_training_plan 及其 time key，然后正常进 ContentView。DB 数据完全不动。

### 版本确认（100% 可靠，防止装旧版）

每次 `dev_flow.sh install` 末尾自动验证装的 App = 当前源码，不再靠猜：
- build 前注入 `git rev-parse --short HEAD` 到 `AppVersion.swift`，build 后恢复 `unset`（不污染工作区）
- 装完自动启动 App、拉 `Documents/version.txt`、对比设备 hash vs 源码 hash
- 输出 `✅ 版本确认：设备 App hash=xxxx = 当前源码` 或 `❌ 版本不一致`

手动验证（不重装）：
```bash
cd Training && bash dev_flow.sh verify
```

先找到编译产物：

```bash
APP=$(find ~/Library/Developer/Xcode/DerivedData/Training-*/Build/Products/Debug-iphoneos/Training.app -maxdepth 0 2>/dev/null | head -1)
echo "$APP"
```

安装：

```bash
xcrun devicectl device install app \
  --device <YOUR_DEVICE_UDID> \
  "$APP"
```

看到 `App installed` 即安装成功。

> ⚠️ **禁止单独 install 旧产物**：`dev_flow.sh install` 现在内部先调 build 再装，并对产物做时间戳校验（10 分钟内），防止 build 失败时误装上一次的旧 .app。手动 `xcrun devicectl device install` 不带 build 也可用，但务必确认刚 `BUILD SUCCEEDED`，否则装的是旧版。

## 四、完整标准流程

严格按此顺序执行，前一步失败则停止：

```
swift test          # 1. 测试
↓ 全部通过
xcodebuild ... build  # 2. 编译
↓ BUILD SUCCEEDED
xcrun devicectl ... install  # 3. 安装
↓ App installed
```

可用 `dev_flow.sh` 快捷执行：

```bash
# 仅测试
cd Training && ./dev_flow.sh test

# 测试 + 编译
cd Training && ./dev_flow.sh build

# 仅安装（需先手动 build）
cd Training && ./dev_flow.sh install

# 测试 + 编译 + 安装 (全流程)
cd Training && ./dev_flow.sh deploy
```

## 五、检查设备 DB（排障时用）

`training.db` 用 **WAL 模式**，未 checkpoint 的写在 `training.db-wal`。**拉 DB 必须连三个文件一起拉**，否则 sqlite3 只读主 `.db` 会看到"空表/缺数据"（误判丢数据）。

```bash
ART=./artifacts/dbcheck && mkdir -p "$ART"
for f in training.db training.db-wal training.db-shm; do
  xcrun devicectl device copy from \
    --device <YOUR_DEVICE_UDID> \
    --domain-type appDataContainer --domain-identifier com.example.Training \
    --source "Documents/$f" --destination "$ART/$f" 2>/dev/null | grep -i received
done
# 三个文件在同级目录，sqlite3 自动合并 WAL
sqlite3 "$ART/training.db" ".tables"
sqlite3 "$ART/training.db" "SELECT COUNT(*) FROM match_schedule;"
```

> ⚠️ **铁律复盘**：曾经只拉主 `training.db`（漏 -wal/-shm），sqlite3 读到空表，误以为"DB 数据丢了/没建表"，实际数据都在 WAL 里。**永远三件套一起拉。**

表结构：`chat_message`（对话/记录花费）、`cost_record`（趋势/训练花费，source=trend/training）、`match_schedule`、`activity_log`、`user_profile`。`sumCost()` = 两者合计。

## 六、XCUITest 自测（可选）

> ⚠️ 注意：项目 `Training.xcodeproj` 当前**没有 TrainingUITests target**（pbxproj 中只有应用本体 target，无 UI 测试 target），且 scheme 未配置 test action。因此 `dev_flow.sh selftest` / `xcodebuild test` 路径**实际无法运行**，会报 `Scheme Training is not currently configured for the test action`。此为历史遗留，待后续补建 UI test target。

### 替代方案：直接驱动 selftest（当前可用方式）

App 启动时读取 launch argument：
- `--self-test` → 进 `SelfTestHostView` 跑全部场景
- `--self-test-scenario=N` → 进 `SelfTestSingleView` 跑第 N 个场景（0 起）

每个场景执行完整对话链路（Planner 真实 API → 工具真实 HealthKit 查询 → Executor 真实回复），并把结构化日志写入 App 沙盒 `Documents/selftest-N.log`：
```
=== SCENARIO|<i>|<name> ===
USER|<用户原话>
PLANNER_RAW|<Planner 返回的完整 JSON>
TOOL|<callId>|<toolName> <param>=<value> ...        （每个工具一行）
TOOL_RESULT|<callId>|<工具完整返回值>                （每个工具一行，含心率序列/睡眠表等）
TEMPLATE|<prompt_template>
EXECUTOR|<Executor 最终回复>
COST|in=..|out=..|cost=..|time=..s
SELFTEST_DONE|single|<name>
```

#### 跑单场景并拉回日志

```bash
# 1. 冷启动某场景（App 已运行时需先重装以杀旧进程）
xcrun devicectl device process launch \
  --device <YOUR_DEVICE_UDID> \
  com.example.Training "--self-test-scenario=N"

# 2. 轮询拉回 selftest-N.log（场景约 30-60s 完成）
ART=./artifacts/logs && mkdir -p "$ART"
for i in $(seq 1 12); do
  sleep 10
  xcrun devicectl device copy from \
    --device <YOUR_DEVICE_UDID> \
    --domain-type appDataContainer \
    --domain-identifier com.example.Training \
    --source "Documents/selftest-N.log" \
    --destination "$ART/selftest-N.log" 2>/dev/null
  if [ -s "$ART/selftest-N.log" ] && grep -q "SELFTEST_DONE" "$ART/selftest-N.log"; then echo "GOT"; break; fi
done
cat "$ART/selftest-N.log"
```

#### 判断

日志拉回后**由 LLM 读取完整调用链判断对错**（不做规则断言）：针对 USER 那句话，逐项检查 PLANNER_RAW 调的工具是否充分、TOOL_RESULT 是否真取到数据、EXECUTOR 回复是否合理且无"缺数据"误报。

#### 当前场景清单（index）

| N | 名称 | 问题 | 用途 |
|---|------|------|------|
| 0 | 恢复查询 | 我恢复得怎么样 | 基础恢复 |
| 1 | 训练计划 | 今天练什么 | 计划路由 |
| 2 | 睡眠分析 | 最近一周睡眠质量如何 | 睡眠表 |
| 3 | 记录运动 1 | 昨天踢球60分钟 | log_activity |
| 4 | 记录运动 2 | 前天跑步5公里 | log_activity |
| 5 | 综合查询 | 这周我做了哪些运动 | manual_activities |
| 6 | 单日数据 | 今天走了多少步 | days_ago |
| 7 | 比赛工具 | 我接下来有比赛吗 | match_schedule |
| 8 | 比赛注入 | 接下来一周训练怎么安排 | 训练规划 |
| 9 | 昨天比赛表现 | 我昨天比赛整体表现如何 | get_workout_metrics 时段查询 |
| 10 | 今天状态 | 我今天状态怎么样 | today/range |
| 11 | 赛后恢复 | 我赛后恢复得怎么样 | hours_ago 当前窗口 + 7天趋势 |

## 七、常见问题

### `swift test` 编译失败
- 确认 `Package.swift` 路径正确：`path: "Training/Training"`
- 确认 `exclude` 列表未包含必要的 `.swift` 文件
- 重新 `swift package resolve`

### xcodebuild 签名失败
- 检查 UDID 是否正确：`xcrun devicectl list devices`
- 检查 Bundle ID：`com.example.Training`
- 确认 iPhone 已解锁且信任此 Mac

### 安装失败 "App not found"
- 先确认 build 成功（`BUILD SUCCEEDED`）
- DerivedData 中可能有多份同名前缀的编译产物，用 `find` 确认路径
