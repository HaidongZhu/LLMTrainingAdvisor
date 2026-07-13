import Foundation
import OSLog

private let log = Logger(subsystem: "com.training", category: "ChatViewModel")

private final class NoOpDeepSeekService: DeepSeekService, @unchecked Sendable {
    func chat(model: String, messages: [[String: String]], temperature: Double, maxTokens: Int, timeoutInterval: TimeInterval = 30) async throws -> (content: String, usage: TokenUsage) {
        throw NSError(domain: "TrainingApp", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not configured"])
    }
    func chatStream(model: String, messages: [[String: String]], temperature: Double, maxTokens: Int, timeoutInterval: TimeInterval = 30, onToken: @escaping @Sendable (String) async -> Void) async throws -> TokenUsage {
        throw NSError(domain: "TrainingApp", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not configured"])
    }
}

private final class NoOpMessageStore: MessageStore {
    func insertChatMessage(_ message: ChatMessage) throws {}
    func insertActivityLog(_ activity: ActivityLog) throws {}
    func queryRecentMessages(limit: Int) throws -> [ChatMessage] { return [] }
}

protocol DeepSeekService: AnyObject, Sendable {
    func chat(
        model: String,
        messages: [[String: String]],
        temperature: Double,
        maxTokens: Int,
        timeoutInterval: TimeInterval
    ) async throws -> (content: String, usage: TokenUsage)

    func chatStream(
        model: String,
        messages: [[String: String]],
        temperature: Double,
        maxTokens: Int,
        timeoutInterval: TimeInterval,
        onToken: @escaping @Sendable (String) async -> Void
    ) async throws -> TokenUsage
}

extension DeepSeekService {
    func chatStream(
        model: String,
        messages: [[String: String]],
        temperature: Double,
        maxTokens: Int,
        timeoutInterval: TimeInterval,
        onToken: @escaping @Sendable (String) async -> Void
    ) async throws -> TokenUsage {
        let (content, usage) = try await chat(model: model, messages: messages, temperature: temperature, maxTokens: maxTokens, timeoutInterval: timeoutInterval)
        await onToken(content)
        return usage
    }
}

extension DeepSeekClient: DeepSeekService {}

protocol MessageStore: AnyObject {
    func insertChatMessage(_ message: ChatMessage) throws
    func insertChatMessagePair(_ first: ChatMessage, _ second: ChatMessage) throws
    func insertActivityLog(_ activity: ActivityLog) throws
    func queryRecentMessages(limit: Int) throws -> [ChatMessage]
}

extension MessageStore {
    func insertChatMessagePair(_ first: ChatMessage, _ second: ChatMessage) throws {
        try insertChatMessage(first)
        try insertChatMessage(second)
    }
}

extension DatabaseService: MessageStore {}

@MainActor
@Observable
final class ChatViewModel {
    private(set) var messages: [ChatMessage] = []
    private(set) var errorMessage: String?
    private(set) var isLoading = false
    var selectedTab = 0


    func saveActivity(_ activity: ActivityLog) throws {
        try messageStore.insertActivityLog(activity)
    }

    func deleteActivity(_ activity: ActivityLog) throws {
        if let db = messageStore as? DatabaseService {
            try db.deleteActivity(id: activity.id)
        }
    }

    func loadActivities() throws -> [ActivityLog] {
        guard let db = messageStore as? DatabaseService else { return [] }
        return try db.queryAllActivities()
    }

    /// @Observable 追踪点：costTracker 是普通 class，其内部变化不会被 @Observable 捕获。
    /// 任意 Tab 计费后递增此值，触发费用栏重绘。
    private(set) var costTick: Int = 0

    /// 最近一次 LLM 调用的花费（任意 Tab：对话/趋势/训练/记录）。
    private(set) var lastTurnCost: Double = 0

    /// 触发费用栏刷新。记录本次花费并通知 UI。
    /// 传 nil 时仅刷新累计/会话显示（如对账后）。
    func refreshCosts(lastTurn: Double? = nil) {
        if let lt = lastTurn { lastTurnCost = lt }
        costTick &+= 1
        onCostChanged?(lastTurnCost)
    }

    /// 累计（历史 + 本会话），读 shared 实时值。
    var accumulatedCost: Double {
        _ = costTick  // 绑定 @Observable 追踪
        return costTracker.totalCost()
    }
    /// 本会话累计，读 shared 实时值。
    var sessionCost: Double {
        _ = costTick
        return costTracker.sessionCost()
    }

    private var lastBalance: Double?

    private enum PlannerError: LocalizedError {
        case extractJSONFailed(raw: String)
        case decodeFailed(json: String, raw: String, error: Error)

        var errorDescription: String? {
            switch self {
            case .extractJSONFailed(let raw):
                return "JSON 提取失败\n原始响应:\n\(raw)"
            case .decodeFailed(let json, let raw, let error):
                return "JSON 解码失败: \(error.localizedDescription)\n提取的 JSON:\n\(json)\n原始响应:\n\(raw)"
            }
        }
    }

    func checkReconcile() async -> String {
        let apiKey = AppConfig.deepSeekAPIKey
        do {
            let balance = try await costTracker.fetchBalance(apiKey: apiKey)
            let current = balance.totalCNY
            if let previous = lastBalance {
                let result = costTracker.reconcile(previousBalance: previous, currentBalance: current, localSpend: costTracker.sessionCost())
                lastBalance = current
                let flag = result.flagged ? "⚠️ " : "✅ "
                return "\(flag)差额 ¥\(String(format: "%.4f", result.diff)) 余额 ¥\(String(format: "%.2f", current))"
            } else {
                lastBalance = current
                return "当前余额 ¥\(String(format: "%.2f", current))（再次点击对比）"
            }
        } catch {
            return "余额查询失败: \(error.localizedDescription)"
        }
    }

    func logActivityViaPlanner(_ text: String) async -> String {
        do {
            let decoder = JSONDecoder()
            let planner = try await callPlanner(userText: "请记录以下活动：" + text, systemPrompt: PromptBuilder.recordPlannerSystemPrompt(), decoder: decoder)
            guard let logTool = planner.response.tools.first(where: { $0.name == "log_activity" }) else {
                return "无法识别活动信息"
            }
            let result = await toolRegistry.execute([logTool])
            return result[logTool.callId] ?? "已记录"
        } catch {
            return "记录失败: \(error.localizedDescription)"
        }
    }

    private let deepSeekService: DeepSeekService
    private let messageStore: MessageStore
    private let costTracker: CostTracker
    private let toolRegistry: ToolRegistry
    /// 计费后通知外部（如 DashboardService 持有的临时 VM 通知主 VM 刷新费用栏）。
    var onCostChanged: ((Double) -> Void)?

    init(
        deepSeekService: DeepSeekService,
        messageStore: MessageStore,
        costTracker: CostTracker,
        toolRegistry: ToolRegistry = ToolRegistry()
    ) {
        self.deepSeekService = deepSeekService
        self.messageStore = messageStore
        self.costTracker = costTracker
        self.toolRegistry = toolRegistry
    }

    convenience init() {
        self.init(costTracker: .shared, deepSeekService: nil)
    }

    /// 注入 costTracker（默认全局 shared）与可选 deepSeekService，其余依赖用生产默认值。
    /// 用于训练 Tab 等需要复用全局计费、但保留独立 db/registry 的场景。
    convenience init(
        costTracker: CostTracker = .shared,
        deepSeekService: DeepSeekService? = nil
    ) {
        let db = DatabaseService.live

        let registry = ToolRegistry()
        registry.register(MetricTool())
        registry.register(SleepTableTool())
        registry.register(WorkoutTableTool())
        registry.register(WorkoutMetricsTool())
        registry.register(DailySummaryTool())
        registry.register(ManualActivitiesTool(store: db))
        registry.register(UserProfileTool(store: db))
        registry.register(LogActivityTool(store: db))
        registry.register(MatchScheduleTool(store: db))
        registry.register(SetUserProfileTool(store: db))

        self.init(
            deepSeekService: deepSeekService ?? DeepSeekClient(keyProvider: { AppConfig.deepSeekAPIKey }),
            messageStore: db,
            costTracker: costTracker,
            toolRegistry: registry
        )
    }

    func bootstrap() async {
        guard let db = messageStore as? DatabaseService else { return }
        if let historyTotal = try? db.sumCost() {
            costTracker.setHistoryTotal(historyTotal)
        }
        if let recent = try? db.queryRecentMessages(limit: 100), !recent.isEmpty {
            messages = recent.reversed()  // DB returns newest-first; UI wants oldest-first
        }
    }

    func sendMessage(_ text: String) async {
        isLoading = true
        errorMessage = nil

        let userMessage = ChatMessage(
            id: UUID(),
            role: "user",
            content: text,
            fullRequest: text,
            tokenIn: 0,
            tokenOut: 0,
            cost: 0,
            createdAt: Date()
        )
        messages.append(userMessage)

        // Progress: planner request
        let plannerProgress = ChatMessage(
            id: UUID(), role: "system",
            content: "📋 规划请求",
            fullRequest: "System:\n\(PromptBuilder.plannerSystemPrompt())\n\nUser:\n\(text)",
            tokenIn: 0, tokenOut: 0, cost: 0,
            createdAt: Date()
        )
        messages.append(plannerProgress)

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            var plannerResponse: PlannerResult?
            for attempt in 1...3 {
                do {
                    plannerResponse = try await callPlanner(userText: text, decoder: decoder)
                    break
                } catch let error as PlannerError {
                    if attempt < 3 {
                        log.info("Planner retry \(attempt)/2 after: \(error.localizedDescription)")
                        try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
                    } else {
                        let errorContent = "❌ 规划失败\n\(error.localizedDescription)"
                        errorMessage = error.localizedDescription
                        let fallbackMessage = ChatMessage(
                            id: UUID(), role: "assistant",
                            content: errorContent, fullRequest: errorContent,
                            tokenIn: 0, tokenOut: 0, cost: 0, createdAt: Date()
                        )
                        messages.append(fallbackMessage)
                        try? messageStore.insertChatMessagePair(userMessage, fallbackMessage)
                        isLoading = false
                        return
                    }
                } catch {
                    let errorContent = "❌ API 错误\n\(error.localizedDescription)"
                    errorMessage = error.localizedDescription
                    let fallbackMessage = ChatMessage(
                        id: UUID(), role: "assistant",
                        content: errorContent, fullRequest: errorContent,
                        tokenIn: 0, tokenOut: 0, cost: 0, createdAt: Date()
                    )
                    messages.append(fallbackMessage)
                    try? messageStore.insertChatMessagePair(userMessage, fallbackMessage)
                    isLoading = false
                    return
                }
            }

            guard let plannerResponse else {
                let fallbackMessage = ChatMessage(
                    id: UUID(), role: "assistant",
                    content: "❌ 规划失败\n未知错误", fullRequest: "no response",
                    tokenIn: 0, tokenOut: 0, cost: 0, createdAt: Date()
                )
                messages.append(fallbackMessage)
                try? messageStore.insertChatMessagePair(userMessage, fallbackMessage)
                isLoading = false
                return
            }

            // Planner result (keep planner request, add result)
            let plannerResult = ChatMessage(
                id: UUID(), role: "system",
                content: "📋 规划回复",
                fullRequest: plannerResponse.rawContent,
                tokenIn: plannerResponse.usage.promptTokens,
                tokenOut: plannerResponse.usage.completionTokens,
                cost: plannerResponse.cost,
                createdAt: Date()
            )
            messages.append(plannerResult)

            // Execute tools and fill template
            let toolResults = await toolRegistry.execute(plannerResponse.response.tools)
            var context: [String: String] = [:]
            for (name, result) in toolResults {
                context[name] = result
            }

            // Always inject manual activities so LLM can reference them for any topic.
            // 兜底：无数据时工具返回"无手动记录"，确保 {manual_activities} 占位符被替换，不泄漏给 Executor。
            if context["manual_activities"] == nil,
               let db = messageStore as? DatabaseService {
                let range = plannerResponse.response.tools.compactMap {
                    Int($0.params["range"] ?? "")
                }.first ?? 7
                let manualTool = ManualActivitiesTool(store: db)
                context["manual_activities"] = await manualTool.execute(params: ["range": String(range)])
            }
            let filledTemplate = PromptBuilder.render(plannerResponse.response.promptTemplate, with: context)

            let toolResult = ChatMessage(
                id: UUID(), role: "system",
                content: "🔧 工具查询 (\(toolResults.count) 项)",
                fullRequest: toolResults.map { "\($0.key):\n\($0.value)" }.joined(separator: "\n\n---\n\n"),
                tokenIn: 0, tokenOut: 0, cost: 0,
                createdAt: Date()
            )
            messages.append(toolResult)

            let executorProgress = ChatMessage(
                id: UUID(), role: "system",
                content: "🤖 执行请求",
                fullRequest: "System:\n\(PromptBuilder.systemPrompt())\n\nUser:\n\(filledTemplate)\n\nUser question: \(text)",
                tokenIn: 0, tokenOut: 0, cost: 0,
                createdAt: Date()
            )
            messages.append(executorProgress)

            let matchInfo = (messageStore as? DatabaseService).flatMap { db in
                (try? db.queryUpcomingMatches(limit: 2)).map { formatMatchesForPrompt($0) }
            } ?? nil
            let executorSystemPrompt = PromptBuilder.systemPrompt(matchInfo: matchInfo)
            log.info("Executor sent: \(executorSystemPrompt.count + filledTemplate.count + text.count) chars, waiting...")

            let assistantMessage = ChatMessage(
                id: UUID(), role: "assistant", content: "",
                fullRequest: "", tokenIn: 0, tokenOut: 0, cost: 0, createdAt: Date()
            )
            messages.append(assistantMessage)

            let executorUsage = try await deepSeekService.chatStream(
                model: AppConfig.deepSeekModel,
                messages: [
                    ["role": "system", "content": executorSystemPrompt],
                    ["role": "user", "content": filledTemplate + "\n\nUser question: " + text],
                ],
                temperature: 0.7,
                maxTokens: 4000,
                timeoutInterval: 120,
                onToken: { @MainActor token in
                    if let idx = self.messages.firstIndex(where: { $0.id == assistantMessage.id }) {
                        self.messages[idx].content += token
                    }
                }
            )

            let executorContent = messages.last(where: { $0.role == "assistant" })?.content ?? ""
            log.info("Executor stream done, \(executorContent.count) chars")

            let trimmed = executorContent.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                let errMsg = ChatMessage(
                    id: UUID(), role: "system",
                    content: "❌ Executor 返回空内容",
                    fullRequest: "Executor returned empty content",
                    tokenIn: 0, tokenOut: 0, cost: 0, createdAt: Date()
                )
                messages.append(errMsg)
                isLoading = false
                return
            }

            let executorCost = costTracker.accumulate(usage: executorUsage)
            refreshCosts(lastTurn: plannerResponse.cost + executorCost)

            let fullRequest = buildFullRequest(
                userText: text,
                plannerResponseJSON: plannerResponse.rawContent,
                filledTemplate: filledTemplate,
                executorResponse: executorContent
            )

            if let idx = messages.firstIndex(where: { $0.id == assistantMessage.id }) {
                messages[idx].fullRequest = fullRequest
                messages[idx].tokenIn = plannerResponse.usage.promptTokens + executorUsage.promptTokens
                messages[idx].tokenOut = plannerResponse.usage.completionTokens + executorUsage.completionTokens
                messages[idx].cost = plannerResponse.cost + executorCost
            }

            log.info("Messages count: \(self.messages.count)")

            do {
                let savedAssistant = messages.first(where: { $0.id == assistantMessage.id }) ?? assistantMessage
                try messageStore.insertChatMessagePair(userMessage, savedAssistant)
                log.info("DB Save OK")
            } catch {
                log.error("DB Save FAILED: \(error.localizedDescription)")
            }

        } catch {
            errorMessage = error.localizedDescription
            log.error("\(error.localizedDescription)")
            let errorMsg = ChatMessage(
                id: UUID(), role: "system",
                content: "❌ \(error.localizedDescription)",
                fullRequest: "\(error)",
                tokenIn: 0, tokenOut: 0, cost: 0,
                createdAt: Date()
            )
            messages.append(errorMsg)
        }

        isLoading = false
        log.info("Final messages count: \(self.messages.count), isLoading: \(self.isLoading)")
    }

    private struct PlannerResult {
        let response: PlannerResponse
        let rawContent: String
        let cost: Double
        let usage: TokenUsage
    }

    private func callPlanner(
        userText: String,
        systemPrompt: String? = nil,
        decoder: JSONDecoder
    ) async throws -> PlannerResult {
        let plannerSystemPrompt = systemPrompt ?? PromptBuilder.plannerSystemPrompt()
        log.info("Planner system: \(plannerSystemPrompt.prefix(200))...")
        let (content, usage) = try await deepSeekService.chat(
            model: AppConfig.deepSeekModel,
            messages: [
                ["role": "system", "content": plannerSystemPrompt],
                ["role": "user", "content": userText],
            ],
            temperature: 0.3,
            maxTokens: 4000,
            timeoutInterval: 30
        )
        log.info("Planner response [\(content.count)c]: \(content)")
        if content.isEmpty || content.allSatisfy({ $0.isWhitespace || $0.isNewline }) {
            log.error("Planner returned empty/whitespace-only. Hex: \(content.data(using: .utf8)?.prefix(200).map { String(format: "%02x", $0) }.joined() ?? "nil")")
        }
        let cost = costTracker.accumulate(usage: usage)

        let jsonCandidate = extractJSON(from: content)
        guard let data = jsonCandidate.data(using: .utf8) else {
            throw PlannerError.extractJSONFailed(raw: content)
        }
        do {
            let response = try decoder.decode(PlannerResponse.self, from: data)
            return PlannerResult(response: response, rawContent: content, cost: cost, usage: usage)
        } catch {
            throw PlannerError.decodeFailed(json: jsonCandidate, raw: content, error: error)
        }
    }

    private func extractJSON(from text: String) -> String {
        Self._extractJSONForTesting(text)
    }

    private func formatMatchesForPrompt(_ matches: [MatchSchedule]) -> String? {
        guard !matches.isEmpty else { return nil }
        let df = DateFormatter(); df.dateFormat = "MM-dd"
        return matches.prefix(2).map { m in
            let d = df.string(from: m.date)
            let t = m.time.map { " \($0)" } ?? ""
            return "- \(d)\(t) \(m.intensity ?? "")"
        }.joined(separator: "\n")
    }

    static func _extractJSONForTesting(_ text: String) -> String {
        var s = text
        if let fenceStart = s.range(of: "```") {
            var body = String(s[fenceStart.upperBound...])
            if body.hasPrefix("json") { body = String(body.dropFirst(4)) }
            if let fenceEnd = body.range(of: "```") { body = String(body[..<fenceEnd.lowerBound]) }
            s = body
        }
        let chars = Array(s)
        var start: Int?, depth = 0, inString = false, escaped = false
        for i in 0..<chars.count {
            let c = chars[i]
            if inString { if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }; continue }
            switch c {
            case "\"": inString = true
            case "{": if depth == 0 { start = i }; depth += 1
            case "}": if depth > 0 { depth -= 1; if depth == 0, let st = start { return String(chars[st...i]) } }
            default: break
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func buildFullRequest(userText: String, plannerResponseJSON: String, filledTemplate: String, executorResponse: String) -> String {
        """
        === PHASE 1: 数据规划 (Planner) ===

        [SYSTEM]
        \(PromptBuilder.plannerSystemPrompt())

        [USER]
        \(userText)

        [PLANNER RESPONSE]
        \(plannerResponseJSON)


        === PHASE 2: 教练回复 (Executor) ===

        [SYSTEM]
        \(PromptBuilder.systemPrompt())

        [USER DATA]
        \(filledTemplate)

        [EXECUTOR RESPONSE]
        \(executorResponse)
        """
    }

}
