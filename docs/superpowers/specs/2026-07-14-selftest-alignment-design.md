# 自测体系对齐与补强设计

> 修正自 @dev 的方案 A。review 中删除了一项伪 bug，新增一项结构性消重。本设计只补对齐与防御性场景，不引入 mock 抽象。

## 背景

自测现有三层：L1 单测（`swift test`）、L2 集成自测（`dev_flow.sh selftest`，XCUITest）、L3 运行时自测（`SelfTestRunner.runAll()`）。三者场景数应一致对齐，但实际：

| 层 | 机制 | 场景数 | 来源 |
|----|------|--------|------|
| L1 单测 | `swift test` | 175 tests / 27 suites | `Tests/` |
| L2 XCUITest | `TrainingUITests.swift` | **9**（test01–test09 → 场景 0–8） | `TrainingUITests.swift:24-32` |
| L3 SelfTestRunner | `scenarios` 数组 | **16**（场景 0–15） | `SelfTestRunner.swift:97-114` 与 `234-250` |

事实定位（已逐行核验）：

1. **XCUITest 缺 7 个场景**：`test01–test09` 覆盖场景 0–8，场景 9–15（昨天比赛表现 / 今天状态 / 今天0点至今 / 查昨天RHR / 查前天RHR / 7天RHR表 / 赛后恢复）在 L2 完全缺失。
2. **`dev_flow.sh` 报表名数组只列 9 个**：`generate_report` 的 `names` 数组（`dev_flow.sh:193`）是 9 项，与 L3 的 16 场景不对齐，跑全量后报表会错位。
3. **`scenarios` 数组重复定义两份**：`runAll()`（`:97-114`）与 `runOne()`（`:234-250`）各持一份完全相同的 16 场景数组。改一处忘改另一处必然漂移。
4. **无 API Key 前置校验**：`runAll()` 直接发请求，key 缺失/失效时 16 场景静默失败，不易定位根因。
5. **无错误路径场景**：16 场景全 happy-path，缺 malformed JSON / 空内容 / 超时 / 无意义输入。
6. **无 DB 一致性场景**：记录运动→未验证 `activity_log` 落库；画像读写未端到端验证。

## 根因

非功能性 bug，而是历史增量留下的对齐债：L3 场景从 9 扩到 16 时，L2（XCUITest）与报表脚本未同步；场景数组在 L3 内部因 `runAll`/`runOne` 各需访问而复制了一份，未抽公共源。

## 目标

- L2 XCUITest 场景数与 L3 对齐（9 → 16）。
- `dev_flow.sh` 报表名数组与 L3 对齐（9 → 16）。
- 消除 `scenarios` 数组重复定义，收敛为单一数据源。
- 自测入口有 API Key 健康检查，失败时给出明确根因。
- 补充最低成本错误路径与 DB 一致性场景。

## 非目标

- **不**引入 `MockDeepSeekClient` 或 `MockHealthDataService`（方案 B/C）。`ChatViewModel` 当前依赖注入链路不为测试而拆，避免污染生产边界。等"API 成本/稳定性阻塞测试"成为真问题再走协议抽象，届时用协议而非条件分支。
- **不**改 test09 的映射（见下「伪 bug 说明」）。
- **不**改工具协议、prompt、模型。

## 伪 bug 说明（不修）

@dev 曾报「test09 映射错位」为缺口。核验后判定为**伪 bug**：

- `TrainingUITests.swift:32` — `test09_matchInjection { launchScenario(8) }`
- `SelfTestRunner.swift:106` — 场景 8 name = 「比赛注入」

XCUITest 用 **1-based 编号**（test01 → 场景 0），故 test09 → 场景 8 → 比赛注入，语义自洽。若按原方案把 test09 改为场景 9，会丢掉场景 8 覆盖。**此条删除，保持现状。**

## 设计

### T1. 抽取场景单一数据源（前置，优先做）

在 `SelfTestRunner` 顶部新增：

```swift
static let allScenarios: [SelfTestScenario] = [ /* 16 项，原 :97-114 内容 */ ]
```

`runAll()` 与 `runOne(index:)` 均改为引用 `SelfTestRunner.allScenarios`，删除两处局部数组。

**理由**：T2 要往场景表里新增项，必须先收敛数据源，否则要往两份数组各加一遍。

### T2. 补齐 XCUITest 7 个缺失场景

在 `TrainingUITests.swift` 新增：

```swift
@MainActor func test10_yesterdayMatchPerf()   { launchScenario(9,  timeout: 90) }
@MainActor func test11_todayStatus()           { launchScenario(10, timeout: 60) }
@MainActor func test12_todayMidnightNow()      { launchScenario(11, timeout: 60) }
@MainActor func test13_yesterdayRHR()          { launchScenario(12, timeout: 60) }
@MainActor func test14_dayBeforeRHR()          { launchScenario(13, timeout: 60) }
@MainActor func test15_sevenDayRHRTable()      { launchScenario(14, timeout: 60) }
@MainActor func test16_postMatchRecovery()     { launchScenario(15, timeout: 90) }
```

timeout 参照现有同类场景：查询类 60s，含 LLM 长输出的 90s。

### T3. `dev_flow.sh` 报表名数组扩到 16

`generate_report` 的 `names`（`:193`）从 9 项扩为 16 项，顺序与 `allScenarios` 严格一致：

```bash
local names=("恢复查询" "训练计划" "睡眠分析" "记录运动 1" "记录运动 2" \
  "综合查询" "单日数据" "比赛工具" "比赛注入" "昨天比赛表现" \
  "今天状态" "今天0点至今" "查昨天RHR" "查前天RHR" "7天RHR表" "赛后恢复")
```

**顺序约束**：XCUITest / SelfTestRunner / dev_flow 三处的场景顺序必须一致，否则 index ↔ name 错位。

### T4. API Key 前置校验

`runAll()` 开头、发任何场景前，做一次轻量健康检查：

- 读取 Keychain 中的 API Key（`KeychainStore`，f259ad0 已迁移至此）。
- 缺失或为空 → 全部 16 场景直接标记 `.error`，detail 写明「API Key 缺失」，不发起请求。

**不做**真实 API 探活（避免额外费用与时延），仅校验存在性。真实失效由首个场景的真实失败暴露。

### T5. 新增错误路径场景（接入 L3）

在 `allScenarios` 追加（不新增 XCUITest，因这些走 L3 即可）：

- malformed JSON：注入一个返回非 JSON 的 Planner 响应路径
- 空内容：Executor 返回空字符串
- 超时：构造一个必然超时的请求

> 实现约束：错误注入需走 `ChatViewModel` 既有的可测注入点；若无干净注入点，**降级为单测覆盖**（在 `Tests/` 里用现有 mock 能力验证 `DeepSeekClient`/`Planner` 解析失败路径），不强改生产代码。此条若 @dev 评估改动超过 ~30 行或触及生产边界，**转为单测**并在此 spec 注明。

### T6. 新增 DB 一致性场景

- 记录运动后查 `activity_log` 表确有落库
- 设置画像 → 读取画像一致

走 L3 `SelfTestRunner` 或 L1 单测，视 `DatabaseService` 现有可测性而定。

## 顺序与依赖

```
T1 (抽 allScenarios) ──► T2 (补 XCUITest) ──► T3 (dev_flow names)
                    └──► T4 (Key 校验)
                    └──► T5 (错误路径)
                    └──► T6 (DB 一致性)
```

T1 是 T2/T3 的前置（数据源先收敛）。T4/T5/T6 相互独立，可并行。

## 测试策略

- T1：编译通过 + `runAll()`/`runOne()` 行为不变（跑现有 9 场景对照）。
- T2：`dev_flow.sh selftest` 跑满 16 场景全绿。
- T3：报表 16 行名目与场景一一对应，无错位。
- T4：手动清空 Keychain → `runAll()` 全部标记 error 且 detail 含「API Key」。
- T5/T6：见各任务实现方式（L3 或单测）。

## 风险

- **T2 timeout 取值偏保守**：新 7 场景的 timeout 按类比估，首个真实跑可能个别偏紧。缓解：首次跑观察实际耗时再微调。
- **T5 强行注入污染生产边界**：已用「>30 行或触及生产边界即降级为单测」约束兜底。
- **三处顺序漂移**：T3 的顺序约束是硬性合约，review 时须逐项核对。
