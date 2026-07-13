# LLM Training Advisor

AI 驱动的私人健康与运动教练 iOS App。基于 DeepSeek 的两阶段推理（Planner → Executor），结合 Apple HealthKit 数据，提供个性化的恢复分析、训练计划与比赛管理。

> 面向任何关注个人运动与健康的人：结合 RHR / HRV / 睡眠 / 训练负荷等生理指标与运动日程，给出具体可执行的训练与恢复建议。

## 核心特性

- **两阶段推理**：Planner（低温、选工具）→ 工具执行（HealthKit + SQLite）→ Executor（高温、生成回复），推理链路可追溯。
- **HealthKit 集成**：支持 ~25 种指标（步数 / 静息心率 / HRV / VO2max / 运动分钟 / 睡眠阶段 / 训练记录）。
- **五大 Tab**：趋势、训练、比赛、记录、对话。
- **趋势分析**：过去 7 天健康数据按主题分段生成报告，6h TTL 缓存 + 自动刷新。
- **比赛管理**：录入比赛日程，自动匹配 Watch 训练记录，比赛信息注入 Executor 上下文。
- **自然语言记录**：口语化输入（"昨天踢球 60 分钟"）解析并持久化。
- **费用追踪**：实时显示本次 / 会话 / 累计 token 费用，支持与 DeepSeek 余额对账。
- **系统自测**：9 个独立 XCUITest 场景，覆盖工具选择、计划生成、数据整合等关键链路。

## 技术栈

| 层 | 技术 |
|----|------|
| UI | SwiftUI + `@Observable` |
| 并发 | Swift Concurrency（async/await, `@MainActor`, actor） |
| AI | DeepSeek API (`deepseek-v4-pro`) |
| 健康数据 | Apple HealthKit |
| 本地存储 | SQLite3（WAL 模式，串行队列） |
| 测试 | Swift Testing（单元）+ XCUITest（集成） |
| 构建 | Swift Package Manager + xcodebuild + devicectl |
| 最低部署 | iOS 18 / macOS 15 |

## 架构

```
用户输入
   │
   ▼  Planner  (temp=0.3, maxTokens=1000, timeout=30s)
   │  → JSON: { tools: [...], prompt_template }
   ▼
ToolRegistry.execute()  →  HealthKit / SQLite 工具（串行）
   │  + manual_activities & match_info 自动注入
   ▼
PromptBuilder.render(template, context)
   │
   ▼  Executor (temp=0.7, maxTokens=2000, timeout=120s)
   │
   ▼  ChatMessage → SQLite 持久化 → UI 显示
```

关键组件：

- `ChatViewModel` — 核心对话引擎，两阶段推理编排，依赖注入可测。
- `ToolRegistry` + `HealthTool` — 可扩展的工具协议体系。
- `DeepSeekClient`（actor）— URLSession + 3 次重试 + 指数退避 + jitter；5xx 重试、4xx 不重试。
- `DatabaseService.live`（单例）— SQLite 封装，5 张表，`PRAGMA user_version` 迁移。
- `DashboardService` — 训练计划与趋势分析的缓存查询引擎（6h TTL）。

详见 [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) 与 [`docs/SPEC.md`](docs/SPEC.md)。

## 快速开始

### 前置要求

- macOS 15+ / Xcode 16+
- Swift 6.0
- 一个 [DeepSeek API Key](https://platform.deepseek.com/)

### 配置 API Key

复制示例文件并填入自己的 key（`Secrets.swift` 已被 `.gitignore`，不会进入版本控制）：

```bash
cp Training/Training/Secrets.swift.example Training/Training/Secrets.swift
```

```swift
enum Secrets {
    static let deepSeekAPIKey = "your-api-key-here"
}
```

### 运行测试

```bash
swift test
```

### 构建与部署（真机）

```bash
./Training/dev_flow.sh build      # 编译
./Training/dev_flow.sh install    # 安装到默认设备
./Training/dev_flow.sh selftest   # 运行 9 个 XCUITest 自测场景
```

## 项目结构

```
Training/
├── Package.swift               # SPM 定义（TrainingApp + Tests）
├── Training/                   # Xcode App 工程
│   ├── Training/               # 源码
│   │   ├── ChatViewModel.swift        # 两阶段推理引擎
│   │   ├── DeepSeekClient.swift       # API 客户端（actor）
│   │   ├── DatabaseService.swift      # SQLite 封装
│   │   ├── DashboardService.swift     # 趋势/计划缓存
│   │   ├── HealthDataService.swift    # HealthKit 工具层
│   │   ├── Tools/                     # HealthTool 实现
│   │   └── ...
│   └── dev_flow.sh             # 构建/测试/部署脚本
├── Tests/TrainingAppTests/     # Swift Testing 单元测试
└── docs/                       # SPEC / ARCHITECTURE / CHANGELOG 等
```

## 安全说明

- API Key 通过本地 `Secrets.swift` 注入，不进入版本控制。
- 伤病历史、比赛节奏等均为 App 内私密数据，纯本地存储，无网络同步。
- 本仓库已重建为干净历史，不含任何泄露的密钥。

## License

私人项目，暂未开源授权。
