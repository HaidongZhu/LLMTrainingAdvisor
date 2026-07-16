import Foundation
import HealthKit

@MainActor
@Observable
final class DashboardService {
    private(set) var trainingPlan: String?
    private(set) var weeklyTrend: String?
    private(set) var trendSections: [(title: String, content: String)] = []
    private(set) var trainingUpdatedAt: Date?
    private(set) var trendUpdatedAt: Date?
    private(set) var isLoadingTraining = false
    private(set) var isLoadingTrend = false
    private(set) var trainingError: String?
    private(set) var trendError: String?

    private(set) var streamingTrendContent: String = ""
    /// 训练 Tab 流式缓冲（专用 prompt 一次 chatStream，非 Planner 链路）。
    private(set) var streamingTrainingContent: String = ""

    private let ttl: TimeInterval = 6 * 3600
    private let defaults = UserDefaults.standard

    /// 共享全局计费器：趋势/训练 Tab 的 LLM 调用累计到这里，
    /// 与对话/记录 Tab（ChatViewModel）共用同一实例，顶部费用栏统一显示。
    private let costTracker: CostTracker
    private let deepSeekService: DeepSeekService
    /// 计费后通知主 ChatViewModel 刷新费用栏（跨 Tab 计费触发 UI 重绘）。
    private var onCostChanged: ((Double) -> Void)?

    /// 运行时注入计费回调（ContentView 在 viewModel 就绪后调用）。
    func setCostChangedHandler(_ handler: @escaping (Double) -> Void) {
        onCostChanged = handler
    }

    init(
        costTracker: CostTracker = .shared,
        deepSeekService: DeepSeekService = DeepSeekClient(keyProvider: { AppConfig.deepSeekAPIKey }),
        onCostChanged: ((Double) -> Void)? = nil
    ) {
        self.costTracker = costTracker
        self.deepSeekService = deepSeekService
        self.onCostChanged = onCostChanged
        loadCache()
    }

    /// 累计本次花费、写 cost_record 持久化、通知 UI 刷新。
    /// 趋势/训练的花费写 cost_record（不污染对话历史），使 bootstrap sumCost 跨会话不丢。
    @discardableResult
    private func accumulateCost(usage: TokenUsage, source: String) -> Double {
        let cost = costTracker.accumulate(usage: usage)
        try? DatabaseService.live.insertCostRecord(
            source: source, tokenIn: usage.promptTokens, tokenOut: usage.completionTokens, cost: cost
        )
        onCostChanged?(cost)
        return cost
    }

    private var trainingCacheKey: String { "dashboard_training_plan" }
    private var trainingTimeKey: String { "dashboard_training_time" }
    private var trendCacheKey: String { "dashboard_weekly_trend" }
    private var trendTimeKey: String { "dashboard_trend_time" }

    func loadCache() {
        if let text = defaults.string(forKey: trainingCacheKey),
           let time = defaults.object(forKey: trainingTimeKey) as? Date,
           Date().timeIntervalSince(time) < ttl {
            trainingPlan = text
            trainingUpdatedAt = time
        } else {
            // 过期或无缓存：清空内存状态，使 autoRefreshDashboard 的 == nil 判断触发刷新。
            trainingPlan = nil
            trainingUpdatedAt = nil
        }
        if let text = defaults.string(forKey: trendCacheKey),
           let time = defaults.object(forKey: trendTimeKey) as? Date,
           Date().timeIntervalSince(time) < ttl {
            weeklyTrend = text
            trendUpdatedAt = time
            parseSections(text)
        } else {
            weeklyTrend = nil
            trendUpdatedAt = nil
            trendSections = []
        }
    }

    func refreshTrainingPlan() async {
        guard !isLoadingTraining else { return }
        isLoadingTraining = true
        trainingError = nil
        trainingPlan = nil
        streamingTrainingContent = ""

        let data = await collectTrainingData()
        guard !data.isEmpty else {
            trainingError = "无数据"
            isLoadingTraining = false
            trainingPlan = defaults.string(forKey: trainingCacheKey)
            return
        }

        do {
            let usage = try await deepSeekService.chatStream(
                model: AppConfig.deepSeekModel,
                messages: [
                    ["role": "system", "content": PromptBuilder.trainingPlanSystemPrompt()],
                    ["role": "user", "content": PromptBuilder.trainingPlanUserData(data)],
                ],
                temperature: 0.3,
                maxTokens: 4000,
                timeoutInterval: 120,
                onToken: { @MainActor token in
                    self.streamingTrainingContent += token
                }
            )
            accumulateCost(usage: usage, source: "training")

            let content = streamingTrainingContent
            guard !content.isEmpty else {
                trainingError = "未获取到回复"
                isLoadingTraining = false
                trainingPlan = defaults.string(forKey: trainingCacheKey)
                return
            }
            trainingPlan = content
            trainingUpdatedAt = Date()
            defaults.set(content, forKey: trainingCacheKey)
            defaults.set(Date(), forKey: trainingTimeKey)
        } catch {
            trainingError = error.localizedDescription
            trainingPlan = defaults.string(forKey: trainingCacheKey)
        }
        isLoadingTraining = false
    }

    /// 训练 Tab 固定取数：今日恢复 + 未来比赛 + 近几天负荷。不走 Planner，直接喂专用 prompt。
    private func collectTrainingData() async -> String {
        var blocks: [String] = []
        let metricTool = MetricTool()

        // 今日恢复状态（今天0点到现在）
        let rhr = await metricTool.execute(params: ["metric": "rhr", "today": "true", "output": "summary"])
        let hrv = await metricTool.execute(params: ["metric": "hrv", "today": "true", "output": "summary"])
        var recovery: [String] = ["=== 今日恢复状态 ==="]
        if rhr != "—" { recovery.append("今日 RHR: \(rhr)") }
        if hrv != "—" { recovery.append("今日 HRV: \(hrv)") }

        // 昨晚睡眠
        let sleepTool = SleepTableTool()
        let sleep = await sleepTool.execute(params: ["range": "2"])
        if sleep.hasPrefix("|") { recovery.append("睡眠:\n\(sleep)") }
        if recovery.count > 1 { blocks.append(recovery.joined(separator: "\n")) }

        // 未来比赛日程
        if let upcoming = try? DatabaseService.live.queryUpcomingMatches(limit: 3), !upcoming.isEmpty {
            let rows = upcoming.map { m -> String in
                let t = m.time ?? ""
                let opp = m.opponent ?? ""
                let inten = m.intensity ?? ""
                return "\(shortDate(m.date)) \(matchRelDate(m.date)) \(t) \(opp) (\(inten))".trimmingCharacters(in: .whitespaces)
            }
            blocks.append("=== 未来比赛 ===\n" + rows.joined(separator: "\n"))
        }
        // 近几天负荷（过去3天）
        let workoutTool = WorkoutTableTool()
        let workout = await workoutTool.execute(params: ["range": "3"])
        if workout.hasPrefix("|") { blocks.append("=== 近几天负荷 ===\n\(workout)") }
        let manualTool = ManualActivitiesTool(store: DatabaseService.live)
        let manual = await manualTool.execute(params: ["range": "3"])
        if manual.hasPrefix("|"), !manual.contains("无手动记录") { blocks.append("人工记录:\n\(manual)") }

        return blocks.joined(separator: "\n\n")
    }

    func refreshWeeklyTrend() async {
        guard !isLoadingTrend else { return }
        isLoadingTrend = true
        trendError = nil
        weeklyTrend = nil
        streamingTrendContent = ""

        let data = await collectWeeklyData()
        guard !data.isEmpty else {
            trendError = "无 HealthKit 数据"
            isLoadingTrend = false
            return
        }

        do {
            let usage = try await deepSeekService.chatStream(
                model: AppConfig.deepSeekModel,
                messages: [
                    ["role": "system", "content": PromptBuilder.weeklyTrendSystemPrompt()],
                    ["role": "user", "content": PromptBuilder.weeklyTrendUserData(data)],
                ],
                temperature: 0.3,
                maxTokens: 5000,
                timeoutInterval: 120,
                onToken: { @MainActor token in
                    self.streamingTrendContent += token
                }
            )
            accumulateCost(usage: usage, source: "trend")

            weeklyTrend = streamingTrendContent
            trendUpdatedAt = Date()
            parseSections(streamingTrendContent)
            defaults.set(streamingTrendContent, forKey: trendCacheKey)
            defaults.set(Date(), forKey: trendTimeKey)
        } catch {
            trendError = error.localizedDescription
        }
        isLoadingTrend = false
    }

    private func collectWeeklyData() async -> String {
        var blocks: [String] = []
        let store = HKHealthStore()
        let cal = Calendar.current

        let metricKeys: [(String, HKQuantityTypeIdentifier, HKStatisticsOptions, @Sendable (Double) -> Double)] = [
            ("rhr", .restingHeartRate, .discreteAverage, { $0 }),
            ("hrv", .heartRateVariabilitySDNN, .discreteAverage, { $0 }),
            ("steps", .stepCount, .cumulativeSum, { $0 }),
            ("运动分钟", .appleExerciseTime, .cumulativeSum, { $0 / 60.0 }),
        ]

        for (name, id, opts, converter) in metricKeys {
            let byDay = await HealthDataService.dailyStatistics(store: store, id: id, options: opts, days: 7, converter: converter)
            guard !byDay.isEmpty else { continue }
            var rows = ["日期 | \(name)"]
            for offset in HealthDataService.dayOffsets(inclusiveDays: 7) {  // 今天~6天前
                let day = cal.startOfDay(for: cal.date(byAdding: .day, value: offset, to: Date())!)
                if let v = byDay[day] {
                    rows.append("\(shortDate(day)) | \(String(format: "%.0f", v))")
                }
            }
            blocks.append(rows.joined(separator: "\n"))
        }

        // 今天细粒度（0点到现在）：平均心率全天连续采样，能反映今日波动曲线
        let metricTool = MetricTool()
        let todayHrTable = await metricTool.execute(params: ["metric": "average_heart_rate", "today": "true", "output": "table"])
        let todayHrSummary = await metricTool.execute(params: ["metric": "average_heart_rate", "today": "true", "output": "summary"])
        var todayBlock: [String] = ["=== 今天 (\(shortDate(Date()))) 细粒度 ==="]
        if todayHrSummary != "—" { todayBlock.append("今日平均心率: \(todayHrSummary)") }
        if todayHrTable != "—" { todayBlock.append("心率逐5分钟:\n\(todayHrTable)") }
        if todayBlock.count > 1 { blocks.append(todayBlock.joined(separator: "\n")) }

        let sleepTool = SleepTableTool()
        let sleepResult = await sleepTool.execute(params: ["range": "7"])
        if sleepResult.hasPrefix("|") { blocks.append("睡眠数据:\n\(sleepResult)") }

        let workoutTool = WorkoutTableTool()
        let workoutResult = await workoutTool.execute(params: ["range": "7"])
        if workoutResult.hasPrefix("|") { blocks.append("训练记录:\n\(workoutResult)") }

        let manualTool = ManualActivitiesTool(store: DatabaseService.live)
        let manualResult = await manualTool.execute(params: ["range": "7"])
        if manualResult.hasPrefix("|"), !manualResult.contains("无手动记录") {
            blocks.append("人工记录:\n\(manualResult)")
        }

        // 未来比赛日程（供下周展望）
        if let upcoming = try? DatabaseService.live.queryUpcomingMatches(limit: 3), !upcoming.isEmpty {
            let rows = upcoming.map { m -> String in
                let t = m.time ?? ""
                let opp = m.opponent ?? ""
                let inten = m.intensity ?? ""
                return "\(shortDate(m.date)) \(matchRelDate(m.date)) \(t) \(opp) (\(inten))".trimmingCharacters(in: .whitespaces)
            }
            blocks.append("=== 未来比赛 ===\n" + rows.joined(separator: "\n"))
        }

        return blocks.joined(separator: "\n\n")
    }

    private func parseSections(_ text: String) {
        var sections: [(title: String, content: String)] = []
        var currentTitle = ""
        var currentContent = ""

        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                if !currentTitle.isEmpty {
                    sections.append((currentTitle, currentContent.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
                currentTitle = String(line.dropFirst(3))
                currentContent = ""
            } else {
                if !currentTitle.isEmpty { currentContent += line + "\n" }
            }
        }
        if !currentTitle.isEmpty {
            sections.append((currentTitle, currentContent.trimmingCharacters(in: .whitespacesAndNewlines)))
        }

        trendSections = sections
    }

    private func shortDate(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MM-dd"; return f.string(from: d)
    }

    /// 比赛相对今天的人类可读描述：周X，距今N天（0=今天，1=明天，2=后天）。
    /// 代码替 LLM 算好，避免 LLM 推算"明天/后天"出错。
    private func matchRelDate(_ d: Date) -> String {
        let cal = Calendar.current
        let dayDiff = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: d)).day ?? 0
        let weekdayIdx = (cal.component(.weekday, from: d) - 1) % 7
        let weekday = ["周日","周一","周二","周三","周四","周五","周六"][weekdayIdx]
        let rel: String
        switch dayDiff {
        case 0: rel = "今天"
        case 1: rel = "明天"
        case 2: rel = "后天"
        case let n where n > 0: rel = "\(n)天后"
        default: rel = "\(-dayDiff)天前"
        }
        return "\(weekday) \(rel)"
    }
}
