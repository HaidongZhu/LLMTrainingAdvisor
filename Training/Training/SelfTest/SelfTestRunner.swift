import SwiftUI

struct SelfTestResult: Identifiable {
    let id = UUID()
    let name: String
    let index: Int
    var status: Status
    var detail: String
    var duration: String
    var messages: [ChatMessage] = []

    enum Status { case pending, running, executed, error, cancelled }
}

/// 自测场景：一句话驱动完整对话链路（Planner→工具→Executor）。
struct SelfTestScenario {
    let name: String
    let message: String
    /// 是否用注入了未来比赛日程的 VM（影响训练规划类场景）。
    let useMatchVM: Bool
    /// 若提供，走 logActivityViaPlanner 记录运动而非普通对话。
    let logActivityInput: String?

    init(name: String, message: String, useMatchVM: Bool = false, logActivityInput: String? = nil) {
        self.name = name
        self.message = message
        self.useMatchVM = useMatchVM
        self.logActivityInput = logActivityInput
    }
}

@MainActor
@Observable
final class SelfTestRunner {
    var results: [SelfTestResult] = []
    var isRunning = false
    var allDone = false

    private var logLines: [String] = []
    var singleScenarioIndex: Int? = nil

    private func makeViewModel() -> ChatViewModel {
        let db = try! DatabaseService(databasePath: ":memory:")
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
        return ChatViewModel(
            deepSeekService: DeepSeekClient(keyProvider: { AppConfig.deepSeekAPIKey }),
            messageStore: db,
            costTracker: CostTracker.shared,
            toolRegistry: registry
        )
    }

    private func makeViewModelWithMatch() -> ChatViewModel {
        let db = try! DatabaseService(databasePath: ":memory:")
        let match = MatchSchedule(
            id: UUID(), date: Date().addingTimeInterval(86400 * 3), time: "20:00",
            opponent: "老男孩", intensity: "high", notes: nil,
            actualDurationMin: nil, actualIntensity: nil, isCompleted: false, createdAt: Date()
        )
        try! db.insertMatchSchedule(match)
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
        return ChatViewModel(
            deepSeekService: DeepSeekClient(keyProvider: { AppConfig.deepSeekAPIKey }),
            messageStore: db,
            costTracker: CostTracker.shared,
            toolRegistry: registry
        )
    }

    func runAll() async {
        guard !isRunning else { return }
        isRunning = true
        allDone = false
        logLines = []
        cleanupLogs()

        let scenarios: [SelfTestScenario] = [
            SelfTestScenario(name: "恢复查询",   message: "我恢复得怎么样"),
            SelfTestScenario(name: "训练计划",   message: "今天练什么"),
            SelfTestScenario(name: "睡眠分析",   message: "最近一周睡眠质量如何"),
            SelfTestScenario(name: "记录运动 1",  message: "", logActivityInput: "昨天踢球60分钟"),
            SelfTestScenario(name: "记录运动 2",  message: "", logActivityInput: "前天跑步5公里"),
            SelfTestScenario(name: "综合查询",   message: "这周我做了哪些运动"),
            SelfTestScenario(name: "单日数据",   message: "今天走了多少步"),
            SelfTestScenario(name: "比赛工具",   message: "我接下来有比赛吗", useMatchVM: true),
            SelfTestScenario(name: "比赛注入",   message: "接下来一周训练怎么安排", useMatchVM: true),
            SelfTestScenario(name: "昨天比赛表现", message: "我昨天比赛整体表现如何"),
            SelfTestScenario(name: "今天状态",   message: "我今天状态怎么样"),
            SelfTestScenario(name: "今天0点至今", message: "帮我看看今天0点到现在的身体状态"),
            SelfTestScenario(name: "查昨天RHR", message: "我昨天的静息心率是多少"),
            SelfTestScenario(name: "查前天RHR", message: "我前天的静息心率是多少"),
            SelfTestScenario(name: "7天RHR表", message: "我最近7天每天的静息心率是多少"),
            SelfTestScenario(name: "赛后恢复",   message: "我赛后恢复得怎么样"),
        ]

        results = scenarios.enumerated().map {
            SelfTestResult(name: $1.name, index: $0, status: .pending, detail: "", duration: "")
        }

        let vm = makeViewModel()
        let vmWithMatch = makeViewModelWithMatch()

        for (i, scenario) in scenarios.enumerated() {
            let useVM = scenario.useMatchVM ? vmWithMatch : vm
            let ok = await runOne(i, vm: useVM, scenario: scenario)
            if !ok {
                for j in (i+1)..<scenarios.count {
                    results[j].status = .cancelled
                    results[j].detail = "前序场景失败，已跳过"
                }
                break
            }
        }

        let executed = results.filter { $0.status == .executed }.count
        let failed = results.filter { $0.status == .error }.count
        let line = "SELFTEST_DONE|\(executed)/\(results.count) executed, \(failed) failed"
        logLines.append(line)
        print(line)

        writeLogFile()
        isRunning = false
        allDone = true
    }

    private func runOne(_ index: Int, vm: ChatViewModel, scenario: SelfTestScenario) async -> Bool {
        results[index].status = .running
        let start = Date()
        var buf: [String] = []

        buf.append("=== SCENARIO|\(index)|\(scenario.name) ===")

        if let logInput = scenario.logActivityInput {
            let r = await vm.logActivityViaPlanner(logInput)
            buf.append("LOG_ACTIVITY_RESULT|\(r.replacingOccurrences(of: "\n", with: "\\n"))")
        } else {
            await vm.sendMessage(scenario.message)
        }

        let msgs = vm.messages
        let lastUser = msgs.last(where: { $0.role == "user" })?.content
        let plannerMsg = msgs.last(where: { $0.role == "system" && $0.content.contains("规划回复") })
        let toolResultMsg = msgs.last(where: { $0.role == "system" && $0.content.contains("🔧 工具查询") })
        let executorMsg = msgs.last(where: { $0.role == "assistant" })

        if let u = lastUser { buf.append("USER|\(u.replacingOccurrences(of: "\n", with: "\\n"))") }
        else if scenario.logActivityInput != nil { buf.append("USER|记录: \(scenario.logActivityInput!)") }

        if let plannerMsg {
            buf.append("PLANNER_RAW|\(plannerMsg.fullRequest.replacingOccurrences(of: "\n", with: "\\n"))")
            if let data = plannerMsg.fullRequest.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tools = json["tools"] as? [[String: Any]] {
                for tool in tools {
                    let tn = tool["name"] as? String ?? "?"
                    let cid = tool["call_id"] as? String ?? "?"
                    let params = (tool["params"] as? [String: String])?.map { "\($0.key)=\($0.value)" }.joined(separator: " ") ?? ""
                    buf.append("TOOL|\(cid)|\(tn) \(params)")
                }
                if let tmpl = json["prompt_template"] as? String {
                    buf.append("TEMPLATE|\(tmpl.replacingOccurrences(of: "\n", with: "\\n"))")
                }
            }
        } else {
            buf.append("PLANNER_RAW|(no valid JSON)")
        }

        // 工具执行结果：来自 "🔧 工具查询" system message 的 fullRequest，格式 "callId:\n<result>\n\n---\n\ncallId:\n<result>"
        if let tr = toolResultMsg, !tr.fullRequest.isEmpty {
            let chunks = tr.fullRequest.components(separatedBy: "\n\n---\n\n")
            for chunk in chunks {
                if let colonRange = chunk.range(of: ":\n") {
                    let callId = String(chunk[..<colonRange.lowerBound])
                    let result = String(chunk[colonRange.upperBound...])
                    buf.append("TOOL_RESULT|\(callId)|\(result.replacingOccurrences(of: "\n", with: "\\n"))")
                }
            }
        }

        if let executorMsg {
            buf.append("EXECUTOR|\(executorMsg.content.replacingOccurrences(of: "\n", with: "\\n"))")
        } else {
            buf.append("EXECUTOR|(no assistant reply)")
        }

        var totalIn = 0, totalOut = 0, totalCost: Double = 0
        for msg in msgs {
            totalIn += msg.tokenIn
            totalOut += msg.tokenOut
            totalCost += msg.cost
        }
        let elapsed = Date().timeIntervalSince(start)
        buf.append("COST|in=\(totalIn)|out=\(totalOut)|cost=\(String(format: "%.6f", totalCost))|time=\(String(format: "%.2f", elapsed))s")

        let text = buf.joined(separator: "\n")
        print(text)
        logLines.append(text)

        results[index].status = .executed
        results[index].detail = "in=\(totalIn) out=\(totalOut) ¥\(String(format: "%.5f", totalCost))"
        results[index].duration = String(format: "%.1fs", elapsed)
        results[index].messages = msgs
        return true
    }

    func runSingle(_ index: Int) async {
        guard !isRunning else { return }
        isRunning = true
        allDone = false
        logLines = []
        cleanupLogs()
        singleScenarioIndex = index

        let scenarios: [SelfTestScenario] = [
            SelfTestScenario(name: "恢复查询",   message: "我恢复得怎么样"),
            SelfTestScenario(name: "训练计划",   message: "今天练什么"),
            SelfTestScenario(name: "睡眠分析",   message: "最近一周睡眠质量如何"),
            SelfTestScenario(name: "记录运动 1",  message: "", logActivityInput: "昨天踢球60分钟"),
            SelfTestScenario(name: "记录运动 2",  message: "", logActivityInput: "前天跑步5公里"),
            SelfTestScenario(name: "综合查询",   message: "这周我做了哪些运动"),
            SelfTestScenario(name: "单日数据",   message: "今天走了多少步"),
            SelfTestScenario(name: "比赛工具",   message: "我接下来有比赛吗", useMatchVM: true),
            SelfTestScenario(name: "比赛注入",   message: "接下来一周训练怎么安排", useMatchVM: true),
            SelfTestScenario(name: "昨天比赛表现", message: "我昨天比赛整体表现如何"),
            SelfTestScenario(name: "今天状态",   message: "我今天状态怎么样"),
            SelfTestScenario(name: "今天0点至今", message: "帮我看看今天0点到现在的身体状态"),
            SelfTestScenario(name: "查昨天RHR", message: "我昨天的静息心率是多少"),
            SelfTestScenario(name: "查前天RHR", message: "我前天的静息心率是多少"),
            SelfTestScenario(name: "7天RHR表", message: "我最近7天每天的静息心率是多少"),
            SelfTestScenario(name: "赛后恢复",   message: "我赛后恢复得怎么样"),
        ]

        guard index < scenarios.count else { return }
        let scenario = scenarios[index]
        results = [SelfTestResult(name: scenario.name, index: 0, status: .pending, detail: "", duration: "")]

        let vm = scenario.useMatchVM ? makeViewModelWithMatch() : makeViewModel()
        _ = await runOne(0, vm: vm, scenario: scenario)

        let line = "SELFTEST_DONE|single|\(scenario.name)"
        logLines.append(line)
        print(line)

        writeLogFile()
        isRunning = false
        allDone = true
    }

    private func cleanupLogs() {
        guard let dir = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first else { return }
        for file in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            where file.hasPrefix("selftest") && file.hasSuffix(".log") {
            let suffix = singleScenarioIndex.map { "-\($0)" } ?? ""
            if file == "selftest\(suffix).log" {
                try? FileManager.default.removeItem(atPath: dir + "/" + file)
            }
        }
    }

    private func writeLogFile() {
        guard let dir = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first else { return }
        let suffix = singleScenarioIndex.map { "-\($0)" } ?? ""
        let path = dir + "/selftest\(suffix).log"
        try? logLines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}

struct SelfTestHostView: View {
    let singleScenario: Int?
    @State private var runner = SelfTestRunner()
    @State private var expandedIndex: Int? = nil

    init(singleScenario: Int? = nil) {
        self.singleScenario = singleScenario
    }

    var body: some View {
        let executed = runner.results.filter { $0.status == .executed }.count
        let failed = runner.results.filter { $0.status == .error }.count
        let total = runner.results.count
        VStack(spacing: 0) {
            HStack {
                Text("自测模式").font(.headline)
                Spacer()
                if runner.allDone {
                    let text = failed > 0 ? "❌ \(executed)/\(total)" : "✅ \(executed)/\(total)"
                    Text("SELFTEST_DONE")
                        .font(.subheadline).monospacedDigit()
                        .foregroundColor(.clear)
                        .overlay(
                            Text(text).font(.subheadline).monospacedDigit()
                                .foregroundColor(failed > 0 ? .red : .green)
                        )
                        .accessibilityIdentifier("SELFTEST_DONE")
                } else if runner.isRunning {
                    ProgressView().scaleEffect(0.8)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.ultraThinMaterial)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(runner.results) { item in
                        VStack(spacing: 0) {
                            Button {
                                withAnimation {
                                    expandedIndex = expandedIndex == item.index ? nil : item.index
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    Group {
                                        switch item.status {
                                        case .pending:   Text("○")
                                        case .running:   ProgressView().scaleEffect(0.6)
                                        case .executed:  Text("✅")
                                        case .error:     Text("❌")
                                        case .cancelled: Text("⏭️")
                                        }
                                    }
                                    .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.name).font(.subheadline)
                                        if !item.detail.isEmpty {
                                            Text(item.detail)
                                                .font(.caption2).foregroundColor(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Text(item.duration).font(.caption2).foregroundColor(.secondary)
                                }
                                .padding(.horizontal, 16).padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if expandedIndex == item.index, !item.messages.isEmpty {
                                chatHistoryView(item.messages)
                            }
                            Divider().padding(.leading, 16)
                        }
                    }
                }
            }

            Button(runner.allDone ? "重新运行" : "运行中...") {
                expandedIndex = nil
                Task {
                    if let idx = singleScenario {
                        await runner.runSingle(idx)
                    } else {
                        await runner.runAll()
                    }
                }
            }
            .disabled(runner.isRunning)
            .buttonStyle(.borderedProminent)
            .padding(12)
        }
        .task {
            if let idx = singleScenario {
                await runner.runSingle(idx)
            } else {
                await runner.runAll()
            }
        }
    }

    private func chatHistoryView(_ messages: [ChatMessage]) -> some View {
        VStack(spacing: 0) {
            ForEach(messages) { msg in
                HStack(alignment: .top) {
                    Text(roleIcon(msg.role))
                        .font(.caption2).foregroundColor(.secondary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(msg.content)
                            .font(.caption.weight(msg.role == "assistant" ? .semibold : .regular))
                            .foregroundColor(msg.role == "system" ? .secondary : .primary)
                        if msg.role == "system", !msg.fullRequest.isEmpty {
                            Text(msg.fullRequest)
                                .font(.caption2).foregroundColor(.secondary)
                                .lineLimit(15)
                        }
                        if msg.cost > 0 || msg.tokenIn > 0 {
                            Text("¥\(String(format: "%.4f", msg.cost)) · in:\(msg.tokenIn) out:\(msg.tokenOut)")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 3)
                .background(msg.role == "assistant" ? Color.blue.opacity(0.05) : Color.clear)
            }
        }
        .padding(.vertical, 4)
    }

    private func roleIcon(_ role: String) -> String {
        switch role {
        case "user": return "U"
        case "assistant": return "A"
        default: return "S"
        }
    }
}

struct SelfTestSingleView: View {
    let scenarioIndex: Int
    var body: some View {
        SelfTestHostView(singleScenario: scenarioIndex)
    }
}
