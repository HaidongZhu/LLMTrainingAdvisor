import HealthKit

final class MetricTool: HealthTool, @unchecked Sendable {
    let name = "get_metric"
    private let store = HKHealthStore()

    /// 所有支持的指标：name → (类型, 统计选项, 单位转换)。单一数据源，WorkoutMetricsTool 复用。
    static let metrics: [String: (HKQuantityTypeIdentifier, HKStatisticsOptions, @Sendable (Double) -> Double)] = [
        "steps": (.stepCount, .cumulativeSum, { $0 }),
        "active_calories": (.activeEnergyBurned, .cumulativeSum, { $0 }),
        "basal_calories": (.basalEnergyBurned, .cumulativeSum, { $0 }),
        "exercise_minutes": (.appleExerciseTime, .cumulativeSum, { $0 / 60.0 }),
        "rhr": (.restingHeartRate, .discreteAverage, { $0 }),
        "hrv": (.heartRateVariabilitySDNN, .discreteAverage, { $0 }),
        "average_heart_rate": (.heartRate, .discreteAverage, { $0 }),
        "vo2_max": (.vo2Max, .discreteAverage, { $0 }),
        "respiratory_rate": (.respiratoryRate, .discreteAverage, { $0 }),
        "walking_speed": (.walkingSpeed, .discreteAverage, { $0 }),
        "flights_climbed": (.flightsClimbed, .cumulativeSum, { $0 }),
        "walking_running_km": (.distanceWalkingRunning, .cumulativeSum, { $0 / 1000.0 }),
        "cycling_distance_km": (.distanceCycling, .cumulativeSum, { $0 / 1000.0 }),
        "walking_heart_rate": (.walkingHeartRateAverage, .discreteAverage, { $0 }),
        "stand_minutes": (.appleStandTime, .cumulativeSum, { $0 / 60.0 }),
        "walking_asymmetry_pct": (.walkingAsymmetryPercentage, .discreteAverage, { $0 }),
        "double_support_pct": (.walkingDoubleSupportPercentage, .discreteAverage, { $0 }),
        "step_length_cm": (.walkingStepLength, .discreteAverage, { $0 * 100.0 }),
        "stair_ascent_speed": (.stairAscentSpeed, .discreteAverage, { $0 }),
        "stair_descent_speed": (.stairDescentSpeed, .discreteAverage, { $0 }),
        "physical_effort": (.physicalEffort, .discreteAverage, { $0 }),
        "oxygen_saturation": (.oxygenSaturation, .discreteAverage, { $0 }),
        "environmental_audio": (.environmentalAudioExposure, .discreteAverage, { $0 }),
        "walking_steadiness": (.appleWalkingSteadiness, .discreteAverage, { $0 }),
        "body_mass_kg": (.bodyMass, .discreteAverage, { $0 }),
    ]

    /// metric 名 → HKQuantityTypeIdentifier（供 WorkoutMetricsTool 复用，避免重复映射表）。
    static func id(for metric: String) -> HKQuantityTypeIdentifier? {
        metrics[metric]?.0
    }

    func execute(params: [String: String]) async -> String {
        guard let metric = params["metric"],
              let (id, opts, converter) = Self.metrics[metric] else {
            return "—"
        }
        let output = params["output"] ?? "summary"

        // today=true：今天 0:00 → now 的时段查询（优先级最高，忽略 range/days_ago/hours_ago）
        if params["today"]?.lowercased() == "true" {
            let cal = Calendar.current
            let now = Date()
            guard let start = cal.date(bySettingHour: 0, minute: 0, second: 0, of: now) else { return "—" }
            return await queryWindow(id: id, opts: opts, converter: converter, start: start, end: now, metric: metric, output: output)
        }

        // hours_ago + duration_hours：任意相对时段（如赛后 1h 恢复）
        if let haStr = params["hours_ago"], let ha = Double(haStr),
           let dhStr = params["duration_hours"], let dh = Double(dhStr) {
            let end = Date().addingTimeInterval(-ha * 3600)
            let start = end.addingTimeInterval(-dh * 3600)
            return await queryWindow(id: id, opts: opts, converter: converter, start: start, end: end, metric: metric, output: output)
        }

        // days_ago：单日定位（如昨天/前天）。不依赖 range，优先于 guard range。
        if let daysAgoStr = params["days_ago"], let daysAgo = Int(daysAgoStr) {
            let date = HealthDataService.dateForDaysAgo(daysAgo)
            let v = await queryDay(id: id, opts: opts, date: date, converter: converter)
            return v.map { fmt($0, metric: metric) } ?? "—"
        }

        // range 必填：以下分支（table / summary）都需要 range。
        guard let rangeStr = params["range"], let range = Int(rangeStr) else {
            return "—"
        }

        if output == "table" {
            return await queryTable(id: id, opts: opts, converter: converter, range: range, metric: metric)
        }

        // Summary mode: aggregate + trend（range 含今天）
        let cal = Calendar.current
        let byDay = await HealthDataService.dailyStatistics(store: store, id: id, options: opts, days: range, converter: converter)
        var values: [Double] = []
        for offset in HealthDataService.dayOffsets(inclusiveDays: range) {
            let day = cal.startOfDay(for: cal.date(byAdding: .day, value: offset, to: Date())!)
            if let v = byDay[day] {
                values.append(v)
            }
        }
        guard !values.isEmpty else { return "—" }
        let avg = values.reduce(0, +) / Double(values.count)
        let trend: String
        if values.count >= 3 {
            let firstHalf = values.prefix(values.count/2).reduce(0,+) / Double(values.count/2)
            let secondHalf = values.suffix(values.count/2).reduce(0,+) / Double(values.count/2)
            let diff = secondHalf - firstHalf
            trend = diff > 1 ? "↑上升" : diff < -1 ? "↓下降" : "→稳定"
        } else {
            trend = ""
        }
        return "\(fmt(avg, metric: metric)) \(trend)"
    }

    private func queryTable(id: HKQuantityTypeIdentifier, opts: HKStatisticsOptions, converter: @escaping @Sendable (Double) -> Double, range: Int, metric: String) async -> String {
        let cal = Calendar.current
        let byDay = await HealthDataService.dailyStatistics(store: store, id: id, options: opts, days: range, converter: converter)
        var rows = ["日期 | 值"]
        for offset in HealthDataService.dayOffsets(inclusiveDays: range) {
            let day = cal.startOfDay(for: cal.date(byAdding: .day, value: offset, to: Date())!)
            if let v = byDay[day] {
                let ds = ds(day)
                rows.append("\(ds) | \(fmt(v, metric: metric))")
            }
        }
        return rows.count > 1 ? rows.joined(separator: "\n") : "—"
    }

    private func queryWindow(id: HKQuantityTypeIdentifier, opts: HKStatisticsOptions, converter: @escaping @Sendable (Double) -> Double, start: Date, end: Date, metric: String, output: String) async -> String {
        if output == "table" {
            // 5min 桶序列
            let buckets = await HealthDataService.bucketStatistics(
                store: store, id: id,
                options: [.discreteMin, .discreteMax, .discreteAverage],
                start: start, end: end, bucketMinutes: 5, converter: converter
            )
            if buckets.isEmpty { return "—" }
            var rows = ["时间 | avg | min | max"]
            let tf = DateFormatter(); tf.dateFormat = "HH:mm"
            for b in buckets {
                let label = "\(tf.string(from: b.start))"
                let av = b.avg.map { fmt($0, metric: metric) } ?? "—"
                let mn = b.min.map { fmt($0, metric: metric) } ?? "—"
                let mx = b.max.map { fmt($0, metric: metric) } ?? "—"
                rows.append("\(label) | \(av) | \(mn) | \(mx)")
            }
            return rows.joined(separator: "\n")
        }
        // summary：时段聚合
        let pred = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictEndDate)
        let qty = HKQuantityType(id)
        let unit = HealthDataService.unit(for: id)
        let raw: Double? = await withCheckedContinuation { (cont: CheckedContinuation<Double?, Never>) in
            let q = HKStatisticsQuery(quantityType: qty, quantitySamplePredicate: pred, options: opts) { _, stats, _ in
                if opts == .cumulativeSum, let s = stats?.sumQuantity() {
                    cont.resume(returning: converter(s.doubleValue(for: unit)))
                } else if let a = stats?.averageQuantity() {
                    cont.resume(returning: converter(a.doubleValue(for: unit)))
                } else {
                    cont.resume(returning: nil)
                }
            }
            store.execute(q)
        }
        return raw.map { fmt($0, metric: metric) } ?? "—"
    }

    private func querySingle(id: HKQuantityTypeIdentifier, opts: HKStatisticsOptions, converter: @escaping @Sendable (Double) -> Double) async -> Double? {
        let cal = Calendar.current
        let today = Date()
        guard let s = cal.date(bySettingHour: 0, minute: 0, second: 0, of: today),
              let e = cal.date(bySettingHour: 23, minute: 59, second: 59, of: today) else { return nil }
        return await queryDay(id: id, opts: opts, date: today, converter: converter)
    }

    private func queryDay(id: HKQuantityTypeIdentifier, opts: HKStatisticsOptions, date: Date, converter: @escaping @Sendable (Double) -> Double) async -> Double? {
        // 复用 dailyStatistics（HKStatisticsCollectionQuery，anchor + enumerate from anchor to now，按天分桶），
        // 与 queryTable 走同一路径保证桶边界一致。查 daysAgo+1 天（含今天），取目标日桶。
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: date)
        let today = cal.startOfDay(for: Date())
        let span = cal.dateComponents([.day], from: dayStart, to: today).day ?? 0
        let days = max(1, span + 1) // 含今天
        let byDay = await HealthDataService.dailyStatistics(store: store, id: id, options: opts, days: days, converter: converter)
        return byDay[dayStart]
    }

    private func fmt(_ v: Double, metric: String) -> String {
        if metric.contains("heart_rate") || metric == "rhr" || metric == "hrv" {
            return "\(Int(v.rounded())) bpm"
        }
        return String(format: "%.1f", v)
    }

    private func ds(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MM-dd"; return f.string(from: d)
    }
}
