import SwiftUI
import HealthKit
import Combine
import OSLog

private let log = Logger(subsystem: "com.training", category: "ContentView")

struct ContentView: View {
    @State private var viewModel = ChatViewModel()
    @State private var dashboard = DashboardService()
    @Environment(\.scenePhase) private var scenePhase
    @State private var steps: Int = 0
    @State private var rhr: Int = 0
    @State private var hrv: Double = 0
    @State private var vo2max: Double = 0
    @State private var exerciseMin: Int = 0
    @State private var recovery: String = ""
    @State private var lastUserId: UUID?
    private let healthStore = HKHealthStore()
    private let timer = Timer.publish(every: 600, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("\u{1F463} \(steps)").font(.caption2)
                Text("\u{2764}\u{FE0F} \(rhr)").font(.caption2)
                Text("\u{1F49C} \(String(format: "%.1f", hrv))").font(.caption2)
                Text("\u{1FAC1} \(String(format: "%.1f", vo2max))").font(.caption2)
                Text("\u{1F3C3} \(exerciseMin)m").font(.caption2)
                Text(recovery).font(.caption2)
            }
            .padding(.vertical, 6).frame(maxWidth: .infinity).background(.ultraThinMaterial)

            Picker("Tab", selection: $viewModel.selectedTab) {
                Text("趋势").tag(0)
                Text("训练").tag(1)
                Text("比赛").tag(2)
                Text("记录").tag(3)
                Text("对话").tag(4)
            }
            .pickerStyle(.segmented).padding(.horizontal, 8).padding(.vertical, 4)

            if viewModel.selectedTab == 0 {
                WeeklyTrendView(dashboard: dashboard)
            } else if viewModel.selectedTab == 1 {
                TrainingPlanView(dashboard: dashboard)
            } else if viewModel.selectedTab == 2 {
                MatchScheduleView(db: DatabaseService.live)
            } else if viewModel.selectedTab == 3 {
                RecordModeView(viewModel: viewModel)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(viewModel.messages) { message in
                                ChatBubbleView(message: message, isActiveSystem: isActiveSystem(message: message))
                            }
                        }
                        .onAppear {
                            if let lastId = viewModel.messages.last?.id { proxy.scrollTo(lastId, anchor: .bottom) }
                        }
                    }
                    .onChange(of: viewModel.messages.count) { _, _ in
                        if let newestUser = viewModel.messages.last(where: { $0.role == "user" }),
                           newestUser.id != lastUserId {
                            lastUserId = newestUser.id
                            withAnimation { proxy.scrollTo(newestUser.id, anchor: .top) }
                        } else if let lastId = viewModel.messages.last?.id {
                            withAnimation { proxy.scrollTo(lastId, anchor: .bottom) }
                        }
                    }
                    .onChange(of: viewModel.messages.last?.content ?? "") { _, _ in
                        if let lastId = viewModel.messages.last?.id, lastId == viewModel.messages.last(where: { $0.role == "assistant" })?.id {
                            withAnimation { proxy.scrollTo(lastId, anchor: .bottom) }
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                InputBarView(viewModel: viewModel)
            }
            CostBarView(sessionCost: viewModel.lastTurnCost, totalSessionCost: viewModel.sessionCost, accumulatedCost: viewModel.accumulatedCost, onReconcile: { await viewModel.checkReconcile() })
        }
        .task { await viewModel.bootstrap(); await requestHealthAuth(); await refreshStatusBar(); await autoRefreshDashboard(); connectCostHandler() }
        .onChange(of: scenePhase) { _, new in if new == .active { Task { await refreshStatusBar(); await autoRefreshDashboard() } } }
        .onChange(of: viewModel.selectedTab) { _, new in if new == 4 { Task { await refreshStatusBar() } } }
        .onReceive(timer) { _ in Task { await autoRefreshDashboard() } }
    }

    private func isActiveSystem(message: ChatMessage) -> Bool {
        guard message.role == "system" else { return false }
        return message.id == viewModel.messages.last(where: { $0.role == "system" })?.id
    }

    private func requestHealthAuth() async {
        let types: Set<HKSampleType> = [
            HKQuantityType(.stepCount), HKQuantityType(.activeEnergyBurned), HKQuantityType(.basalEnergyBurned),
            HKQuantityType(.restingHeartRate), HKQuantityType(.heartRateVariabilitySDNN), HKQuantityType(.heartRate),
            HKQuantityType(.appleExerciseTime), HKQuantityType(.flightsClimbed), HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.vo2Max), HKQuantityType(.respiratoryRate), HKQuantityType(.walkingSpeed),
            HKQuantityType(.walkingStepLength), HKQuantityType(.physicalEffort), HKQuantityType(.oxygenSaturation),
            HKQuantityType(.bodyMass), HKQuantityType(.environmentalAudioExposure),
            HKQuantityType(.walkingAsymmetryPercentage), HKQuantityType(.walkingDoubleSupportPercentage),
            HKQuantityType(.stairAscentSpeed), HKQuantityType(.stairDescentSpeed), HKQuantityType(.appleWalkingSteadiness),
            HKCategoryType(.sleepAnalysis),
            HKWorkoutType.workoutType(),
        ]
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            healthStore.requestAuthorization(toShare: [], read: types) { success, error in
                log.info("Health auth success=\(success), error=\(String(describing: error))")
                cont.resume()
            }
        }
    }

    private func refreshStatusBar() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let cal = Calendar.current; let today = Date()
        guard let start = cal.date(bySettingHour: 0, minute: 0, second: 0, of: today),
              let end = cal.date(bySettingHour: 23, minute: 59, second: 59, of: today) else { return }
        let pred = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictEndDate)
        if let v = await stat(.stepCount, .cumulativeSum, pred) { steps = Int(v.rounded()) }
        if let v = await stat(.restingHeartRate, .discreteAverage, pred) { rhr = Int(v.rounded()) }
        if let v = await stat(.heartRateVariabilitySDNN, .discreteAverage, pred) { hrv = v }
        if let v = await stat(.vo2Max, .discreteAverage, pred) { vo2max = v }
        if let v = await stat(.appleExerciseTime, .cumulativeSum, pred) { exerciseMin = Int(v / 60.0) }
        let rt = rhr; let ht = hrv
        let rb = await metricAvg(.restingHeartRate, days: 7)
        let hb = await metricAvg(.heartRateVariabilitySDNN, days: 7)
        if rt > 0 && ht > 0, let rBase = rb, let hBase = hb, rBase > 0, hBase > 0 {
            let score = HealthDataService.recoveryScore(hrvToday: ht, hrvBaseline: hBase, rhrToday: Double(rt), rhrBaseline: rBase)
            recovery = score >= 67 ? "\u{1F7E2}\(score)" : score >= 34 ? "\u{1F7E1}\(score)" : "\u{1F534}\(score)"
        }
    }

    private func stat(_ id: HKQuantityTypeIdentifier, _ opts: HKStatisticsOptions, _ pred: NSPredicate) async -> Double? {
        let qty = HKQuantityType(id)
        return await withCheckedContinuation { cont in
            HKStatisticsQuery(quantityType: qty, quantitySamplePredicate: pred, options: opts) { _, stats, _ in
                let result: Double?
                if opts == .cumulativeSum, let s = stats?.sumQuantity() { result = s.doubleValue(for: HealthDataService.unit(for: id)) }
                else if let a = stats?.averageQuantity() { result = a.doubleValue(for: HealthDataService.unit(for: id)) }
                else { result = nil }
                cont.resume(returning: result)
            }.let { healthStore.execute($0) }
        }
    }

    private func metricAvg(_ id: HKQuantityTypeIdentifier, days: Int) async -> Double? {
        let byDay = await HealthDataService.dailyStatistics(store: healthStore, id: id, options: .discreteAverage, days: days, converter: { $0 })
        let vals = Array(byDay.values)
        return vals.isEmpty ? nil : vals.reduce(0, +) / Double(vals.count)
    }

    private func autoRefreshDashboard() async {
        dashboard.loadCache()
        if dashboard.trainingPlan == nil { await dashboard.refreshTrainingPlan() }
        if dashboard.weeklyTrend == nil { await dashboard.refreshWeeklyTrend() }
    }

    /// 把 DashboardService 的计费回调接到主 viewModel，使趋势/训练 Tab 计费后顶部费用栏刷新。
    private func connectCostHandler() {
        dashboard.setCostChangedHandler { [weak viewModel] lastTurn in
            viewModel?.refreshCosts(lastTurn: lastTurn)
        }
    }
}

extension HKStatisticsQuery { func `let`(_ block: (HKStatisticsQuery) -> Void) { block(self) } }

struct InputBarView: View {
    @State private var text = ""
    var viewModel: ChatViewModel
    var body: some View {
        HStack(spacing: 8) {
            TextField("输入消息...", text: $text).textFieldStyle(.roundedBorder).disabled(viewModel.isLoading)
            if viewModel.isLoading { ProgressView().scaleEffect(0.8) }
            Button("发送") { let message = text; text = ""; Task { await viewModel.sendMessage(message) } }
                .disabled(text.isEmpty || viewModel.isLoading)
        }.padding(.horizontal, 12).padding(.vertical, 8)
    }
}

struct CostBarView: View {
    let sessionCost: Double; let totalSessionCost: Double; let accumulatedCost: Double
    var onReconcile: (() async -> String)? = nil
    @State private var reconcileResult: String = ""
    @State private var isChecking = false

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text("\u{672C}\u{6B21} \u{00A5}\(String(format: "%.4f", sessionCost))")
                Text("|"); Text("\u{4F1A}\u{8BDD} \u{00A5}\(String(format: "%.4f", totalSessionCost))")
                Text("|"); Text("\u{7D2F}\u{8BA1} \u{00A5}\(String(format: "%.4f", accumulatedCost))")
                if let onReconcile {
                    Button("对账") {
                        isChecking = true
                        Task {
                            let result = await onReconcile()
                            reconcileResult = result
                            isChecking = false
                        }
                    }
                    .font(.caption2)
                    .disabled(isChecking)
                }
            }
            if !reconcileResult.isEmpty {
                Text(reconcileResult)
                    .font(.caption2)
                    .foregroundColor(reconcileResult.hasPrefix("⚠️") ? .orange : .secondary)
                    .lineLimit(1)
            }
        }
        .font(.caption2).foregroundColor(.secondary).padding(.vertical, 4).frame(maxWidth: .infinity)
    }
}

struct RecordModeView: View {
    var viewModel: ChatViewModel
    @State private var text = ""
    @State private var activities: [ActivityLog] = []
    @State private var isProcessing = false
    @State private var resultMsg = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("如: 昨天踢了60分钟", text: $text).textFieldStyle(.roundedBorder)
                if isProcessing { ProgressView().scaleEffect(0.8) }
                else {
                    Button("记录") {
                        isProcessing = true; resultMsg = ""
                        Task { let msg = await viewModel.logActivityViaPlanner(text); text = ""; isProcessing = false; resultMsg = msg; loadActivities() }
                    }.disabled(text.isEmpty)
                }
            }.padding(.horizontal, 12).padding(.vertical, 8)
            if !resultMsg.isEmpty { Text(resultMsg).font(.caption).foregroundColor(.green).padding(.horizontal, 12) }
            Divider()
            List { ForEach(activities) { a in VStack(alignment: .leading, spacing: 2) { HStack { Text(a.type).font(.headline); Spacer(); Text(fmt(a.date)).font(.caption).foregroundColor(.secondary) }; HStack { if let d = a.durationMin { Text("\(Int(d))min") }; if let d = a.distanceKm { Text("\(String(format:"%.1f",d))km") }; if let i = a.intensity { Text(i) } }.font(.subheadline).foregroundColor(.secondary) } }.onDelete { idx in for i in idx { try? viewModel.deleteActivity(activities[i]) }; loadActivities() } }.listStyle(.plain)
        }.onAppear { loadActivities() }
    }
    private func loadActivities() { activities = (try? viewModel.loadActivities()) ?? [] }
    private func fmt(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "MM-dd"; return f.string(from: d) }
}
