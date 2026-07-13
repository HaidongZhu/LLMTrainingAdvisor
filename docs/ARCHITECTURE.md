# Training App — 架构设计

## 技术栈

| 层 | 技术 |
|----|------|
| UI | SwiftUI + @Observable |
| 并发 | Swift Concurrency (async/await, @MainActor) |
| AI | DeepSeek API (deepseek-v4-pro) |
| 健康数据 | Apple HealthKit |
| 本地存储 | SQLite3（WAL 模式，串行队列） |
| 测试框架 | Swift Testing (单元测试), XCUITest (UI 集成测试) |
| 构建 | xcodebuild + devicectl |
| 最低部署 | iOS 18 / macOS 15 |

## 架构图

```
┌─────────────────────────────────────────────────────┐
│ ContentView                                         │
│  Picker: 趋势 | 训练 | 比赛 | 记录 | 对话            │
├─────────────────────────────────────────────────────┤
│                                                     │
│  WeeklyTrendView ──┐                                │
│  TrainingPlanView ─┤                                │
│                     ├── DashboardService (shared)    │
│                     │   ├── 训练 Plan: ChatViewModel │
│                     │   └── 趋势: direct tools      │
│                     │                                │
│  MatchScheduleView ─┤  DatabaseService.live         │
│                     │  (single instance)            │
│  ChatView ──────────┤  ChatViewModel                │
│                     │   ├── Planner API call        │
│  RecordView ────────┤   ├── ToolRegistry.execute()  │
│                     │   └── Executor API call        │
│                     │                                │
│  SelfTestView ────── SelfTestRunner                  │
│                       └── ChatViewModel (:memory:)   │
└─────────────────────────────────────────────────────┘

外部服务:
  DeepSeek API  ← DeepSeekClient (timeout + retry + backoff)
  HealthKit     ← HealthDataService + Tool implementations
```

## 组件详解

### DatabaseService（单例 `DatabaseService.live`）

SQLite3 封装，5 张表：

```sql
chat_message(id, role, content, full_request, token_in, token_out, cost, created_at)
activity_log(id, date, type, duration_min, distance_km, intensity, notes, created_at)
user_profile(key, value)
match_schedule(id, date, time, opponent, intensity, notes,
               actual_duration_min, actual_intensity, is_completed, created_at)
-- schema_version via PRAGMA user_version
```

- 串行队列 `training.db.serial` 保证线程安全
- `PRAGMA journal_mode=WAL` + `PRAGMA busy_timeout=5000`
- `migrate()` 基于 `PRAGMA user_version`

### ChatViewModel（@MainActor @Observable）

核心对话引擎。

**两阶段推理流程：**

```
sendMessage(text)
  │
  ├─ callPlanner(userText, decoder)
  │   ├─ DeepSeekClient.chat(temp=0.3, maxTokens=1000, timeout=30)
  │   └─ extractJSON + JSONDecoder → PlannerResponse
  │       失败 → PlannerError（带上下文）→ retry 1 次
  │
  ├─ toolRegistry.execute(plannerResponse.tools)
  │   ├─ metric ╮
  │   ├─ sleep  │  for loop, serial
  │   ├─ workout┤
  │   └─ ...    ╯
  │   └─ manual_activities 注入（系统自动，不在 Planner 工具列表里）
  │
  ├─ PromptBuilder.render(template, context)
  │
  ├─ PromptBuilder.systemPrompt(matchInfo: upcomingMatches)
  │
  └─ DeepSeekClient.chat(temp=0.7, maxTokens=2000, timeout=120)
       └─ executorContent → ChatMessage → 持久化
```

**依赖注入：**

```swift
protocol DeepSeekService { func chat(...) }
protocol MessageStore   { func insert/query... }

init(deepSeekService:, messageStore:, costTracker:, toolRegistry:)
convenience init()  // 生产：用 DatabaseService.live + DeepSeekClient
```

### ToolRegistry + HealthTool 协议

```swift
protocol HealthTool {
    var name: String { get }
    func execute(params: [String: String]) async -> String
}

final class ToolRegistry {
    func register(_ tool: HealthTool)
    func execute(_ planned: [PlannedTool]) async -> [String: String]
}
```

- `MetricTool`：支持 ~25 种 HealthKit 指标（步数/RHR/HRV/VO2max 等）
- `SleepTableTool`：睡眠阶段表
- `WorkoutTableTool`：训练记录表
- `DailySummaryTool`：每日关键指标表（步数/RHR/HRV/运动分钟）
- `ManualActivitiesTool`：人工活动记录（DB 查询）
- `UserProfileTool`：用户档案（年龄/身高/体重/伤病）
- `LogActivityTool`：写入活动记录
- `MatchScheduleTool`：未来比赛表

执行计划（`PlannedTool`）支持 JSON + AnyCodable 解析。

### DeepSeekClient（actor）

```swift
actor DeepSeekClient {
    func chat(model:, messages:, temperature:, maxTokens:, timeoutInterval:)
        async throws -> (content: String, usage: TokenUsage)

    // 内部：URLSession + 3 次重试 + 指数退避 + jitter
    // 4xx 不重试, 5xx/networkError 重试
    // 错误类型: DeepSeekClientError (LocalizedError)
}
```

- 超时：Planner 30s，Executor 120s
- API endpoint: `https://api.deepseek.com/chat/completions`
- 模型: `deepseek-v4-pro`

### DashboardService（@MainActor @Observable）

训练计划 + 趋势分析的缓存和查询引擎。

```swift
final class DashboardService {
    var trainingPlan: String?
    var weeklyTrend: String?
    var trendSections: [(title, content)]

    // TTL = 6h
    // UserDefaults 存取
    func loadCache()                    // 启动时检查
    func refreshTrainingPlan() async    // ChatViewModel → 真实 API
    func refreshWeeklyTrend() async     // 直接工具调用 → 专用 prompt → API
    func collectWeeklyData() async      // 并行调用 7 个工具
}
```

### SelfTestRunner（@MainActor @Observable）

自测引擎，支持单场景和全量运行。每个场景创建独立 `ChatViewModel`（`:memory:` DB），执行后收集 Planner/Executor 原始数据，写入 `Documents/selftest-{index}.log`。XCUITest 检测 `SELFTEST_DONE` 完成标记。

### HealthDataService

HealthKit 工具层：

```swift
enum HealthDataService {
    static func unit(for id: HKQuantityTypeIdentifier) -> HKUnit
    static func recoveryScore(hrvToday:, hrvBaseline:, rhrToday:, rhrBaseline:) -> Int
    static func dailyStatistics(store:, id:, options:, days:, converter:) async -> [Date: Double]
    static func convert(value:, key:) -> Double
    static func sleepStage(_ v: Int) -> String
    static func woType(_ t: HKWorkoutActivityType) -> String
}
```

`dailyStatistics` 使用 `HKStatisticsCollectionQuery`（单次查询替代 per-day 循环）。

## 数据流

```
用户输入
  │
  ▼
Planner System Prompt
  │
  ▼
DeepSeek API (Planner)
  │
  ▼
JSON → PlannedTool[]
  │
  ▼
HealthKit / SQLite tools
  │
  ▼
Context: [callId: result]
  │
  ▼ (注入 manual_activities + match info)
  │
  ▼
PromptBuilder.render(template, context)
  │
  ▼
Executor System Prompt (含比赛信息)
  │
  ▼
DeepSeek API (Executor)
  │
  ▼
ChatMessage → DB 持久化 → UI 显示
```

## 错误处理

| 层 | 错误类型 | 处理 |
|----|---------|------|
| Planner | `PlannerError.extractJSONFailed` | retry 1 次 → 显示原始响应 |
| Planner | `PlannerError.decodeFailed` | retry 1 次 → 显示字段错误 |
| API | `DeepSeekClientError.networkError` | retry 3 次 → 停止 |
| API | `DeepSeekClientError.httpError` | 5xx 重试, 4xx 不重试 |
| Executor | 超时 120s | networkError（带 LocalizedError） |
| HealthKit | 无授权 | 返回 "—" |

## 关键设计决策

| 决策 | 理由 |
|------|------|
| DB 单例 `DatabaseService.live` | 避免多连接读写不同步 |
| 自测用 `:memory:` DB | 不污染真实数据 |
| Planner/Executor 超时分层 (30s/120s) | Planner 短回复，Executor 长回复 |
| 工具串行执行 | 避免 HealthKit 并发冲突 |
| Picker 而非 TabView | 5 个 Tab View 太重，Picker 紧凑 |
| 9 个独立 XCUITest | 比单个 120s 更稳定，单场景失败不阻塞 |
| manual_activities 自动注入 | 不依赖 Planner 是否调用 |
| match_info 两路注入 | Planner 工具 + Executor prompt 兜底 |

## 安全

- API Key 存储在 `AppConfig.deepSeekAPIKey`
- 受伤病历史、比赛节奏均为 App 内私密数据
- 无网络数据同步（纯本地）
- 导出包必须脱敏（替换 API Key + 个人数据）

## 未来规划（暂不实施）

- SSE 流式输出（见 `docs/SSE_STREAMING_DESIGN.md`）
- TabView 底部导航（替代窄 Picker）
- 夜间睡眠自动分析
- iCloud 同步
