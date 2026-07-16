# Training App — 剩余 TODO

## 已完成 ✅

- [x] **CostTracker reconcile 对账测试**：fetchBalance + reconcile 对账 UI 已接通
- [x] **P4-T1：os.Logger**：12 处 `print()` 替换为 `os.Logger`
- [x] **P4-T4：补充测试**：新增 12 个测试 (113 tests in 18 suites)
- [x] **P3-T1：HKStatisticsCollectionQuery**：替换 per-day 循环查询
- [x] **P4-T1：迁移数组**：`migrate()` 改为 migrations 数组模式
- [x] **PromptBuilder 示例**：JSON 示例中 `sum7` 去重 + 缺逗号修复
- [x] **自测对齐（16 场景）**：XCUITest / SelfTestRunner / dev_flow 三处对齐
- [x] **HRV 单位修正**：`fmt` 拆分 hrv→ms、心率→bpm
- [x] **时间戳秒级**：planner/executor 统一注入 `yyyy-MM-dd HH:mm:ss EEEE`
- [x] **安全债**：删除 Secrets.swift 硬编码 API Key

## 未闭环

- [ ] **真机验收**：趋势表今天 HRV 与对话 `get_metric(hrv,range=1)` 一致性依赖真机 HealthKit 采样，单测无法覆盖
- [ ] **selftest 链路**：`project.pbxproj` 无 `TrainingUITests` target，`dev_flow.sh selftest` 实际无法通过 xcodebuild 运行；当前可用方案为 launch argument 驱动

## 状态
- 176 tests | 27 suites | Xcode build OK | 无 crash
