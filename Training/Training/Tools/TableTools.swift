import HealthKit
import OSLog

private let log = Logger(subsystem: "com.training", category: "TableTools")

final class SleepTableTool: HealthTool, @unchecked Sendable {
    let name = "get_sleep_table"
    private let store = HKHealthStore()

    func execute(params: [String: String]) async -> String {
        let range = Int(params["range"] ?? "7") ?? 7
        let cal = Calendar.current
        var rows: [String] = ["| 日期 | 总h | 核心 | 深度 | REM | 清醒 |"]

        for offset in HealthDataService.dayOffsets(inclusiveDays: range) {
            let date = cal.date(byAdding: .day, value: offset, to: Date())!
            // Sleep overnight: query from 3pm day-before to 3pm this-day to capture overnight sleep
            guard let s = cal.date(bySettingHour: 15, minute: 0, second: 0, of: cal.date(byAdding: .day, value: -1, to: date)!),
                  let e = cal.date(bySettingHour: 15, minute: 0, second: 0, of: date) else { continue }
            let pred = HKQuery.predicateForSamples(withStart: s, end: e, options: .strictEndDate)
            let samples: [HKCategorySample] = await withCheckedContinuation { cont in
                let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
                let q = HKSampleQuery(sampleType: HKCategoryType(.sleepAnalysis), predicate: pred, limit: 200, sortDescriptors: [sort]) { _, s, _ in
                    cont.resume(returning: (s as? [HKCategorySample]) ?? [])
                }
                store.execute(q)
            }
            log.info("\(self.ds(date)): \(samples.count) samples")
            var core = 0.0, deep = 0.0, rem = 0.0, awake = 0.0
            for s in samples {
                let min = s.endDate.timeIntervalSince(s.startDate) / 60.0
                switch s.value {
                case 3: core += min
                case 4: deep += min
                case 5: rem += min
                case 2: awake += min
                default: break
                }
            }
            let total = core + deep + rem + awake
            if total > 0 {
                let ds = ds(date)
                rows.append("| \(ds) | \(String(format:"%.1f",total/60))h | \(Int(core))m | \(Int(deep))m | \(Int(rem))m | \(Int(awake))m |")
            }
        }
        return rows.count > 1 ? rows.joined(separator: "\n") : "无睡眠数据"
    }

    private func ds(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "MM-dd"; return f.string(from: d) }
}

final class WorkoutTableTool: HealthTool, @unchecked Sendable {
    let name = "get_workout_table"
    private let store = HKHealthStore()

    func execute(params: [String: String]) async -> String {
        let range = Int(params["range"] ?? "7") ?? 7
        let cal = Calendar.current
        let end = Date()
        let start = cal.date(byAdding: .day, value: -range, to: end)!
        var pred = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictEndDate)
        if let typeName = params["type"], let actType = HealthDataService.workoutActivityType(forName: typeName) {
            let typePred = HKQuery.predicateForWorkouts(with: actType)
            pred = NSCompoundPredicate(andPredicateWithSubpredicates: [pred, typePred])
        }
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let samples: [HKWorkout] = await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: HKWorkoutType.workoutType(), predicate: pred, limit: 50, sortDescriptors: [sort]) { _, s, _ in
                cont.resume(returning: (s as? [HKWorkout]) ?? [])
            }
            store.execute(q)
        }
        if samples.isEmpty { return "无训练记录" }
        var rows = ["| 日期 | 类型 | 时长 | 距离 | 热量 |"]
        for w in samples {
            let dur = Int(w.duration / 60.0)
            let dist = (w.totalDistance?.doubleValue(for: .meter()) ?? 0) / 1000.0
            let cal = Int((w.totalEnergyBurned?.doubleValue(for: .kilocalorie()) ?? 0).rounded())
            rows.append("| \(ds(w.startDate)) | \(HealthDataService.woType(w.workoutActivityType)) | \(dur)m | \(String(format:"%.1f",dist))km | \(cal)kcal |")
        }
        return rows.joined(separator: "\n")
    }

    private func ds(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "MM-dd"; return f.string(from: d) }
}

final class WorkoutMetricsTool: HealthTool, @unchecked Sendable {
    let name = "get_workout_metrics"
    private let store = HKHealthStore()

    func execute(params: [String: String]) async -> String {
        guard let typeName = params["type"],
              let actType = HealthDataService.workoutActivityType(forName: typeName),
              let metric = params["metric"] else {
            return "缺少必要参数（type/metric）"
        }
        let cal = Calendar.current

        // date 可选：传则查指定日期那场；不传则查最近一场（默认过去 14 天内最近）。
        if let dateStr = params["date"] {
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"; df.timeZone = cal.timeZone
            guard let day = df.date(from: dateStr) else { return "日期格式错误，需 yyyy-MM-dd" }
            guard let dayStart = cal.date(bySettingHour: 0, minute: 0, second: 0, of: day),
                  let dayEnd = cal.date(bySettingHour: 23, minute: 59, second: 59, of: day) else { return "—" }
            var timePred = HKQuery.predicateForSamples(withStart: dayStart, end: dayEnd, options: .strictEndDate)
            let typePred = HKQuery.predicateForWorkouts(with: actType)
            timePred = NSCompoundPredicate(andPredicateWithSubpredicates: [timePred, typePred])
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            let workouts: [HKWorkout] = await withCheckedContinuation { cont in
                let q = HKSampleQuery(sampleType: HKWorkoutType.workoutType(), predicate: timePred, limit: 1, sortDescriptors: [sort]) { _, s, _ in
                    cont.resume(returning: (s as? [HKWorkout]) ?? [])
                }
                store.execute(q)
            }
            guard let w = workouts.first else {
                // 指定日期无比赛 → fallback 查最近一场，避免"昨天没比赛"死卡闸门。
                let recent = await queryRecentWorkout(actType: actType)
                guard let rw = recent else { return "未找到 \(dateStr) 的 \(typeName) 训练记录，且近14天无该类型比赛" }
                let metrics = await buildMetrics(w: rw, type: typeName, metric: metric, idParam: metric, output: params["output"] ?? "summary")
                return "（\(dateStr) 无 \(typeName) 比赛，已用最近一场 \(Self.sd(rw.startDate))）\n" + metrics
            }
            return await buildMetrics(w: w, type: typeName, metric: metric, idParam: metric, output: params["output"] ?? "summary")
        } else {
            // 最近一场：过去 14 天内 startDate 倒序取第一场
            guard let w = await queryRecentWorkout(actType: actType) else { return "过去14天无 \(typeName) 训练记录" }
            return await buildMetrics(w: w, type: typeName, metric: metric, idParam: metric, output: params["output"] ?? "summary")
        }
    }

    /// 查最近14天内最近一场该类型 workout。
    private func queryRecentWorkout(actType: HKWorkoutActivityType) async -> HKWorkout? {
        let cal = Calendar.current
        let end = Date()
        let start = cal.date(byAdding: .day, value: -14, to: end)!
        var timePred = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictEndDate)
        let typePred = HKQuery.predicateForWorkouts(with: actType)
        timePred = NSCompoundPredicate(andPredicateWithSubpredicates: [timePred, typePred])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        return await withCheckedContinuation { (cont: CheckedContinuation<HKWorkout?, Never>) in
            let q = HKSampleQuery(sampleType: HKWorkoutType.workoutType(), predicate: timePred, limit: 1, sortDescriptors: [sort]) { _, s, _ in
                cont.resume(returning: (s as? [HKWorkout])?.first)
            }
            store.execute(q)
        }
    }

    private func buildMetrics(w: HKWorkout, type: String, metric: String, idParam: String, output: String) async -> String {
        guard let id = MetricTool.id(for: idParam) else { return "不支持的指标：\(metric)" }
        let unit = HealthDataService.unit(for: id)
        let wStart = w.startDate, wEnd = w.endDate

        if output == "table" {
            let buckets = await HealthDataService.bucketStatistics(
                store: store, id: id, options: [.discreteMin, .discreteMax, .discreteAverage],
                start: wStart, end: wEnd, bucketMinutes: 5, converter: { $0 }
            )
            if buckets.isEmpty { return "无 \(metric) 数据" }
            var rows = ["\(Self.sd(wStart)) \(type) (\(Self.hm(wStart))-\(Self.hm(wEnd))) \(metric) 序列:", "时间 | avg | min | max"]
            for b in buckets {
                let av = b.avg.map { Self.fmt($0, metric: metric) } ?? "—"
                let mn = b.min.map { Self.fmt($0, metric: metric) } ?? "—"
                let mx = b.max.map { Self.fmt($0, metric: metric) } ?? "—"
                rows.append("\(Self.hm(b.start)) | \(av) | \(mn) | \(mx)")
            }
            return rows.joined(separator: "\n")
        }

        // summary：时段 avg/min/max
        let pred = HKQuery.predicateForSamples(withStart: wStart, end: wEnd, options: .strictEndDate)
        let statsTuple: (Double?, Double?, Double?) = await withCheckedContinuation { (cont: CheckedContinuation<(Double?, Double?, Double?), Never>) in
            let q = HKStatisticsQuery(quantityType: HKQuantityType(id), quantitySamplePredicate: pred,
                                      options: [.discreteMin, .discreteMax, .discreteAverage]) { _, stats, _ in
                let av = stats?.averageQuantity().map { $0.doubleValue(for: unit) }
                let mn = stats?.minimumQuantity().map { $0.doubleValue(for: unit) }
                let mx = stats?.maximumQuantity().map { $0.doubleValue(for: unit) }
                cont.resume(returning: (av, mn, mx))
            }
            store.execute(q)
        }
        let (av, mn, mx) = statsTuple
        return "\(Self.sd(wStart)) \(type) \(Self.hm(wStart))-\(Self.hm(wEnd)) \(metric): " +
               "avg \(av.map { Self.fmt($0, metric: metric) } ?? "—") / " +
               "min \(mn.map { Self.fmt($0, metric: metric) } ?? "—") / " +
               "max \(mx.map { Self.fmt($0, metric: metric) } ?? "—")"
    }

    private static func fmt(_ v: Double, metric: String) -> String {
        if metric.contains("heart_rate") || metric == "rhr" || metric == "hrv" { return "\(Int(v.rounded())) bpm" }
        return String(format: "%.1f", v)
    }
    private static func hm(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d) }
    private static func sd(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "MM-dd"; return f.string(from: d) }
}

final class DailySummaryTool: HealthTool, @unchecked Sendable {
    let name = "get_daily_summary"
    private let store = HKHealthStore()

    func execute(params: [String: String]) async -> String {
        let range = Int(params["range"] ?? "7") ?? 7
        let cal = Calendar.current
        let steps = await HealthDataService.dailyStatistics(store: store, id: .stepCount, options: .cumulativeSum, days: range, converter: { $0 })
        let rhr = await HealthDataService.dailyStatistics(store: store, id: .restingHeartRate, options: .discreteAverage, days: range, converter: { $0 })
        let hrv = await HealthDataService.dailyStatistics(store: store, id: .heartRateVariabilitySDNN, options: .discreteAverage, days: range, converter: { $0 })
        let ex = await HealthDataService.dailyStatistics(store: store, id: .appleExerciseTime, options: .cumulativeSum, days: range, converter: { $0 })
        var rows = ["| 日期 | 步数 | RHR | HRV | 运动min |"]
        for offset in HealthDataService.dayOffsets(inclusiveDays: range) {
            let day = cal.startOfDay(for: cal.date(byAdding: .day, value: offset, to: Date())!)
            let sVal = steps[day].map { "\(Int($0.rounded()))" } ?? "—"
            let rVal = rhr[day].map { "\(Int($0.rounded()))" } ?? "—"
            let hVal = hrv[day].map { "\(Int($0.rounded()))" } ?? "—"
            let eVal: String
            if let e = ex[day] { eVal = "\(Int(e/60))m" } else { eVal = "—" }
            let dateStr = ds(day)
            rows.append("| \(dateStr) | \(sVal) | \(rVal) | \(hVal) | \(eVal) |")
        }
        return rows.joined(separator: "\n")
    }

    private func ds(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "MM-dd"; return f.string(from: d) }
}
