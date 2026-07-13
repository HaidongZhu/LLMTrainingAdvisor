# Training App — 产品功能规格

## 概述

AI 驱动的私人健康与运动教练 iOS App。通过 DeepSeek API 进行两阶段推理（Planner → Executor），结合 Apple HealthKit 健康数据，提供个性化的运动恢复分析、训练计划、比赛管理。

**目标用户**：{age} 岁业余足球运动员（后腰/边后卫），每周三和周末比赛，有伤病史。

## Tab 结构

```
趋势 | 训练 | 比赛 | 记录 | 对话
 0      1      2      3      4
```

应用启动时默认停在 **趋势** Tab。

---

## 趋势 Tab

### 功能

展示过去 7 天的健康数据趋势分析，由 AI 按主题分段生成报告。

### 数据采集

跳过 Planner，直接调用 HealthKit 工具同步采集：

| 指标 | 工具 | 查询参数 |
|------|------|---------|
| RHR | MetricTool | range=7, output=table |
| HRV | MetricTool | range=7, output=table |
| 步数 | MetricTool | range=7, output=table |
| 运动分钟 | MetricTool | range=7, output=table |
| 睡眠 | SleepTableTool | range=7 |
| 训练记录 | WorkoutTableTool | range=7 |
| 人工记录 | ManualActivitiesTool | range=7（查真实 DB） |

### AI 分析

专用 prompt（`weeklyTrendPrompt`），要求按 6 段组织输出：

```
## 睡眠质量
## RHR 趋势
## HRV 趋势
## 运动负荷
## 恢复状态
## 综述
```

每段要求结合运动数据解释生理指标的波动原因（如"7月1日 HRV 骤升，当日有 83 分钟比赛"）。

### 显示

按 `## ` 标题解析为可折叠/展开的 section，综述在最底部。

### 缓存

- UserDefaults 存储：文本内容 + 时间戳
- TTL：6 小时
- 过期自动查询（10 分钟定时器 + App 启动 + 回前台）
- 右上角手动刷新按钮

---

## 训练 Tab

### 功能

根据当天身体状态和未来比赛日程，生成具体可执行的训练计划。

### 流程

Planner → ToolRegistry → Executor，跟对话 Tab 相同的两阶段推理。

### Executor 响应要求

- 训练建议必须具体、可执行（"死虫式 10×3，组间 45s"），不能笼统（"做核心训练"）
- 结合 RHR/HRV/睡眠数据判断强度
- 考虑比赛节奏和伤病历史
- **自动注入未来 2 场比赛信息**到 Executor prompt 中

### 缓存

- UserDefaults 存储 + 6h TTL
- 同趋势 Tab 的自动刷新机制
- Planner 失败时显示真实错误信息

---

## 比赛 Tab

### 功能

管理比赛日程，让 AI 感知即将到来的比赛以调整训练计划。

### 新增比赛

- Sheet 表单输入：日期、时间（HH:MM）、强度（高/中/低）、对手（可选）、备注（可选）
- 存入 `match_schedule` 表
- 可编辑、删除未完成的比赛

### 比赛确认

- 日期过了或用户主动点击"确认"
- 输入：实际分钟数、实际强度
- **系统自动查询 Watch**：比赛当天 ± 是否有 Watch 训练记录
  - 检测到匹配 → "Watch 已检测到同期训练记录" ，默认勾选跳过手写记录
  - 用户可取消勾选
- 确认后：更新 `match_schedule`（标记完成 + 实际值）
- 如未跳过手动记录 → 写入 `activity_log`（type="Match"）

### 列表

- **即将到来**：未完成 + 未来日期的比赛
  - 过期未确认的比赛以红色"待确认"标记
- **已完成**：已确认 + 日期已过的比赛
  - 已完成只读，不可编辑

### LLM 集成

- `get_match_schedule` 工具供 Planner 调用
- Executor prompt 自动注入最近 2 场未来比赛（"## 近期比赛"段）

---

## 对话 Tab

### 功能

自然语言问答。用户输入任意问题，AI 分析健康数据后回复。

### 两阶段推理

```
用户提问
  │
  ├─ Planner（温度 0.3, maxTokens 1000）
  │   返回 JSON: {tools: [...], prompt_template: "..."}
  │
  ├─ Tool Registry 执行工具（HealthKit + DB 查询）
  │
  ├─ Executor（温度 0.7, maxTokens 2000）
  │   基于工具结果 + 用户问题返回最终回复
  │
  └─ 显示 + 持久化
```

### Planner 工具清单

- `get_metric(metric, range, output?)` — 各类生理指标
- `get_daily_summary(range)` — 每日关键指标表
- `get_sleep_table(range)` — 睡眠阶段分布
- `get_workout_table(range)` — Watch 训练记录
- `get_manual_activities(range)` — 系统自动注入（Planner 不需要主动调用）
- `get_match_schedule()` — 未来比赛表
- `get_user_profile()` — 用户档案

### Planner 稳定性

- `PlannerError` 带完整上下文（原始响应 + 提取到的 JSON），不再吞错误
- Planner prompt 要求"只输出 JSON，不要任何其他文字"
- 超时 30s，失败重试 1 次

### Executor 配置

- 超时 120s（长回复需要更多时间）
- 自动注入未来比赛、人工运动记录
- 回复原则：
  1. 不主动发散到无关话题
  2. 训练建议必须具体可执行
  3. 结合数据判断强度/恢复
  4. 伤病调整动作选择
  5. 有数据支撑
  6. 数据缺失时明确指出
  7. 安全第一

---

## 记录 Tab

### 功能

用自然语言记录运动活动，AI 解析并持久化。

### 流程

- 用户输入（如"昨天踢球60分钟"）
- `logActivityViaPlanner` → 专用 Planner prompt → `log_activity` 工具
- 写入 `activity_log` 表
- 展示历史记录列表，支持删除

---

## 顶栏

实时显示当日摘要数据：

| 显示 | 指标 | 数据源 |
|------|------|--------|
| 👣 | 步数 | HealthKit .stepCount |
| ❤️ | 静息心率 | HealthKit .restingHeartRate |
| 💜 | 心率变异性 (HRV) | HealthKit .heartRateVariabilitySDNN |
| 🫁 | 最大摄氧量 (VO2max) | HealthKit .vo2Max |
| 🏃 | 运动分钟 | HealthKit .appleExerciseTime |
| 🟢/🟡/🔴 | 恢复评分 | 内部计算（基于 RHR/HRV） |

---

## 费用追踪

底部 CostBar 实时显示：

| 显示 | 含义 |
|------|------|
| 本次 | 当前轮（Planner + Executor）费用 |
| 会话 | 本次会话累计费用 |
| 累计 | 历史 + 会话总费用 |
| 对账 | 查询 DeepSeek 余额 API → 对比本地计费 |

---

## 系统自测

### XCUITest 管线

```
dev_flow.sh selftest
  │
  ├─ xcodebuild test（9 个独立 XCUITest）
  ├─ 每个测试：launch app → --self-test-scenario=N → 等 SELFTEST_DONE
  └─ 输出：selftest-{n}.log + report.md + crash logs
```

### 9 个场景

| # | 场景 | 测试内容 |
|---|------|---------|
| 1 | 恢复查询 | Planner 选择 RHR/HRV/睡眠工具 |
| 2 | 训练计划 | Executor 生成具体可执行计划 |
| 3 | 睡眠分析 | Planner 选择 sleep_table 工具 |
| 4 | 记录运动 1 | 自然语言解析 + DB 写入 |
| 5 | 记录运动 2 | 不同运动类型 |
| 6 | 综合查询 | Watch + 手动数据整合 |
| 7 | 单日数据 | range=1 查询 |
| 8 | 比赛工具 | MatchScheduleTool 调用 |
| 9 | 比赛注入 | 比赛数据进入 Executor 上下文 |

### 产物

```
artifacts/YYYYMMDD_HHMMSS/
├── result.xcresult   # Xcode 测试报告（可双击打开）
├── selftest.log      # 完整结构化日志
├── report.md         # Markdown 格式报告
└── crash/            # Crash 日志（如有）
```
