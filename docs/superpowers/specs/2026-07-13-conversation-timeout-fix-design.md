# 对话超时修复设计

> 与《2026-07-13-llm-provider-abstraction-design》并列的独立工作线；本设计只解决超时，不碰 provider 抽象。

## 背景

对话模式在 Planner 阶段稳定报 `-1001 The request timed out`（日志实锤 `NSURLErrorTimedOut`），趋势/训练正常。

事实定位：

| 链路 | 调用 | 单次 timeout | 位置 |
|------|------|------|------|
| 对话 Planner | `chat`（非流式） | **30s** | `ChatViewModel.swift:471` |
| 对话 Executor | `chatStream` | 120s | `ChatViewModel.swift:381` |
| 训练/趋势 | `chatStream` | 120s | `DashboardService.swift` |

补充事实：
- `DeepSeekClient` 的 `chat` / `chatStream` **都已有 client 层重试**（最多 3 次、指数退避），且 `isRetryable` **已覆盖 `URLError.timedOut`**（`DeepSeekClient.swift:87-103`）。
- `ChatViewModel` 的 Planner 外层重试循环只对 `PlannerError`（JSON 解析类）重试，网络错误走通用 catch——但 client 层已兜底重试，故此处非根因。

## 根因

三条链路共用同一 connection；**timeout 是各调用点自己的参数**。Planner 单次窗口仅 30s，而已确定"每家族统一用一个模型"（当前 DeepSeek `deepseek-v4-pro`，默认思考模式、响应偏慢），30s 不足以等到首个响应；client 层虽重试 3 次，但每次仍是 30s，累计约 90s 后彻底失败。

**决策关联**：既然已定"统一一个模型、不分思考/非思考、不按用途区分"，就**不能**用"给 Planner 换快模型"解决超时——唯一可行解法是**加大 Planner 超时窗口**，与其余链路对齐。

## 目标

- 对话 Planner 不再因单次窗口过短而超时，与 Executor / 训练一致（120s）。

## 非目标

- **不**换模型、**不**分思考/非思考、**不**按用途拆分模型。
- **不**改 provider 抽象（见并列 spec）。
- **不**改 prompt 与工具。
- **不**新增 client 层重试（已存在且已覆盖超时）。

## 设计

1. **核心改动**：`callPlanner` 的 `timeoutInterval: 30` → `120`（`ChatViewModel.swift:471`）。
2. `logActivityViaPlanner` 复用同一 `callPlanner`，自动受益。
3. **复核不改**：Executor（`:381`）、训练/趋势已 120s；client 层重试与 `isRetryable` 已就绪。
4. **消除魔数（可选）**：30 / 120 当前是散落字面量，建议抽一个超时常量集中管理，避免将来漏改。最小实现仅改 `30 → 120`。

## 测试策略

- 注入 mock service：响应 < 120s → Planner 成功；> 120s → 抛超时。
- 断言 `callPlanner` 传入 `timeoutInterval == 120`（防回归改回 30）。
- 回归：Executor / 训练 timeout 不变；self-test 对话场景跑通。

## 风险

- **失败反馈变慢**：单次 30s→120s 叠加重试，最坏等待更长。缓解：与其余链路一致；重试次数有上限；UI 已有 `isLoading`，必要时补"取消"。
- **真实响应 > 120s**（超长输出）仍会超时：属模型/输出长度问题，另议。
