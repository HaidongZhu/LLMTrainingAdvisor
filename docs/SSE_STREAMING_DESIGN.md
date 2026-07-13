# SSE 流式输出 — 设计文档

## 目标

Executor 回复从"等 60 秒一次性返回"改为逐 token 推送，用户 2 秒开始看到文字。覆盖三处：聊天、训练计划、7日趋势。

## DeepSeek SSE 格式

```
data: {"choices":[{"delta":{"content":"你"}}]}
data: {"choices":[{"delta":{"content":"好"}}]}
data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":100,"completion_tokens":50,"total_tokens":150}}
data: [DONE]
```

- `delta.content` = 新增 token
- 最后一条生效行含 `usage`（如 `stream_options.include_usage: true`）
- `[DONE]` = 流结束

## 架构变更

### 1. `content` let → var（`Models.swift`）

```swift
struct ChatMessage {
    var content: String   // 原是 let
    ...
}
```

`@Observable` 自动追踪，UI 实时更新。

### 2. DeepSeekService 协议新增 `chatStream`

```swift
protocol DeepSeekService: AnyObject, Sendable {
    // 现有（Planner 用）
    func chat(...) async throws -> (content, TokenUsage)

    // 新增（Executor 用）
    func chatStream(
        model: String,
        messages: [[String: String]],
        temperature: Double,
        maxTokens: Int,
        timeoutInterval: TimeInterval,
        onToken: @escaping @Sendable (String) async -> Void
    ) async throws -> TokenUsage
}
```

### 3. DeepSeekClient 实现 `chatStream`

- `URLSession.bytes(for:)` 替代 `data(for:)`
- POST body 加 `"stream": true`
- SSE 解析：`data:` 行 → JSON → `onToken(delta.content)`
- 遇到 `[DONE]` 或 `finish_reason` → 返回 usage
- retry 逻辑复用现有实现（3 次 + 退避 + jitter）

### 4. ChatViewModel.sendMessage — Executor 走流式

```swift
// 空消息先挂上
let assistantMsg = ChatMessage(role: "assistant", content: "", ...)
messages.append(assistantMsg)

// 流式填充
let usage = try await deepSeekService.chatStream(
    ...,
    onToken: { token in
        if let idx = self.messages.firstIndex(where: { $0.id == assistantMsg.id }) {
            self.messages[idx].content += token
        }
    }
)

// 流式完成后，检测空内容
guard !assistantMsg.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
    messages.append(ChatMessage(role: "system", content: "❌ Executor 返回空内容", ...))
    return
}
```

### 5. DashboardService — 两个 Tab 走流式

**`refreshTrainingPlan`**：`makeViewModel()` → `sendMessage` → 流式回填 `trainingPlan`（DashboardService 新属性 `streamingTrainingContent`）。

**`refreshWeeklyTrend`**：`DeepSeekClient.chatStream` 调用专用 prompt → `onToken` 追加到 `streamingTrendContent` → 完成后置 `weeklyTrend` 并 `parseSections`。

### 6. DashboardView — 实时显示

```swift
// TrainingPlanView
if dashboard.isLoadingTraining {
    ScrollView {
        Text(dashboard.streamingTrainingContent)
            .font(.body).padding(16)
    }
}

// WeeklyTrendView — 同上 pattern
```

**复制按钮**：流式期间隐藏，`streamingContent` 完成（`isLoadingX == false`）后显示。

### 7. 聊天 Tab 复制按钮

`ChatBubbleView` 的 `contextMenu` 在流式期间（`message.content` 在追加）不限制访问，但实践中不会有用户复制半截内容。`chatStream` 完成前 `isLoading == true` 时内容为空或半截。不需额外处理。

## 不流式的部分

| 组件 | 理由 |
|------|------|
| Planner | ~50 tokens，30s 内完成 |
| 自测 XCUITest | 日志采集，无需流式 |
| `logActivityViaPlanner` | 短回复 |

## 错误处理

| 场景 | 行为 |
|------|------|
| 流中断 | 保留已收内容 + 追加 `[流中断]` 标记 |
| 非 200 | 同现 httpError |
| 网络断 | 同现 networkError + 重试 |
| 空内容 | `chatStream` 返回后检测 → 追加 error 系统消息 |

## 变更清单

| 文件 | 改动量 | 说明 |
|------|--------|------|
| `Models.swift` | 1 行 | `content` let→var |
| `DeepSeekClient.swift` | +40 行 | `chatStream` 实现 |
| `ChatViewModel.swift` | ~10 行改 | Executor 走流式 + 空检测 |
| `DashboardService.swift` | ~30 行改 | 两个方法走流式 + 流式状态 |
| `DashboardView.swift` | ~15 行改 | 流式文本显示 + 复制按钮条件隐藏 |
| `ChatBubbleView.swift` | 不变 | 复制拿 `content`，流式时内容实时更新 |
| `ChatViewModelTests.swift` | +5 行 | Mock 加 `chatStream`（一次性回调） |

## 注意事项

- SSE 解析状态机：`data:` 行 → buffer → 空行触发 JSON 解析
- `onToken` 回调在 `@MainActor` 上执行
- 流式期间 `isLoading` 保持 `true`，完成后布局不会抖动
- 训练计划 Tab 的 `matchInfo` 注入在 `chatStream` 前完成，流式不影响
