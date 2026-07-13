import Foundation
import HealthKit

enum HealthDataService {

    static func unit(for id: HKQuantityTypeIdentifier) -> HKUnit {
        switch id {
        case .stepCount, .flightsClimbed: return .count()
        case .activeEnergyBurned, .basalEnergyBurned: return .kilocalorie()
        case .appleExerciseTime, .appleStandTime: return .second()
        case .distanceWalkingRunning, .distanceCycling, .walkingStepLength: return .meter()
        case .walkingSpeed, .stairAscentSpeed, .stairDescentSpeed: return HKUnit(from: "m/s")
        case .walkingDoubleSupportPercentage, .walkingAsymmetryPercentage,
             .appleWalkingSteadiness, .oxygenSaturation: return .percent()
        case .bodyMass: return HKUnit.gramUnit(with: .kilo)
        case .environmentalAudioExposure: return HKUnit(from: "dBASPL")
        case .heartRate, .restingHeartRate, .walkingHeartRateAverage, .respiratoryRate: return HKUnit(from: "count/min")
        case .heartRateVariabilitySDNN: return HKUnit.secondUnit(with: .milli)
        case .vo2Max: return HKUnit(from: "mL/kg·min")
        case .physicalEffort: return HKUnit(from: "kcal/hr·kg")
        default: return .count()
        }
    }

    static func recoveryScore(hrvToday: Double, hrvBaseline: Double, rhrToday: Double, rhrBaseline: Double) -> Int {
        let hrvScore = max(0, min(100, 50 + ((hrvToday - hrvBaseline) / hrvBaseline) / 0.30 * 50))
        let rhrScore = max(0, min(100, 50 + ((rhrBaseline - rhrToday) / rhrBaseline) / 0.10 * 50))
        return Int(0.6 * hrvScore + 0.4 * rhrScore)
    }

    static func convert(_ v: Double, key: String) -> Double {
        switch key {
        case "exercise_minutes": return v / 60.0
        case "walking_running_km", "cycling_distance_km": return v / 1000.0
        case "step_length_cm": return v * 100.0
        default: return v
        }
    }

    static func sleepStage(_ v: Int) -> String {
        switch v {
        case 0: return "InBed"
        case 1: return "Asleep"
        case 2: return "Awake"
        case 3: return "Core"
        case 4: return "Deep"
        case 5: return "REM"
        default: return "Unk"
        }
    }

    static func woType(_ t: HKWorkoutActivityType) -> String {
        switch t {
        case .running: return "Running"
        case .cycling: return "Cycling"
        case .walking: return "Walking"
        case .hiking: return "Hiking"
        case .soccer: return "Soccer"
        case .stairs: return "Stairs"
        default: return "Other"
        }
    }

    /// 运动名称 → HKWorkoutActivityType，大小写不敏感。football/soccer 都映射到 .soccer。未知返回 nil。
    static func workoutActivityType(forName name: String) -> HKWorkoutActivityType? {
        switch name.lowercased() {
        case "soccer", "football": return .soccer
        case "running": return .running
        case "cycling", "biking": return .cycling
        case "walking": return .walking
        case "hiking": return .hiking
        case "stairs": return .stairs
        case "swimming": return .swimming
        case "yoga": return .yoga
        default: return nil
        }
    }

    static func ts(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: d)
    }

    static func dailyStatistics(
        store: HKHealthStore,
        id: HKQuantityTypeIdentifier,
        options: HKStatisticsOptions,
        days: Int,
        converter: @escaping @Sendable (Double) -> Double
    ) async -> [Date: Double] {
        guard HKHealthStore.isHealthDataAvailable(), days > 0 else { return [:] }
        let cal = Calendar.current
        let endDay = cal.startOfDay(for: Date())
        guard let anchor = cal.date(byAdding: .day, value: -days, to: endDay) else { return [:] }
        let qty = HKQuantityType(id)
        let unit = Self.unit(for: id)
        let predicate = HKQuery.predicateForSamples(withStart: anchor, end: Date(), options: .strictStartDate)
        return await withCheckedContinuation { (cont: CheckedContinuation<[Date: Double], Never>) in
            let q = HKStatisticsCollectionQuery(
                quantityType: qty,
                quantitySamplePredicate: predicate,
                options: options,
                anchorDate: anchor,
                intervalComponents: DateComponents(day: 1)
            )
            q.initialResultsHandler = { _, results, _ in
                var out: [Date: Double] = [:]
                results?.enumerateStatistics(from: anchor, to: Date()) { stat, _ in
                    let quantity = options.contains(.cumulativeSum) ? stat.sumQuantity() : stat.averageQuantity()
                    if let quantity {
                        out[cal.startOfDay(for: stat.startDate)] = converter(quantity.doubleValue(for: unit))
                    }
                }
                cont.resume(returning: out)
            }
            store.execute(q)
        }
    }

    /// 按 N 分钟分桶查询时段内的 min/avg/max 统计。返回每桶一个元组，按时间升序。
    /// options 应包含 .discreteMin/.discreteMax/.discreteAverage（按需）。空桶返回 nil。
    static func bucketStatistics(
        store: HKHealthStore,
        id: HKQuantityTypeIdentifier,
        options: HKStatisticsOptions,
        start: Date,
        end: Date,
        bucketMinutes: Int,
        converter: @escaping @Sendable (Double) -> Double
    ) async -> [(start: Date, min: Double?, avg: Double?, max: Double?)] {
        guard HKHealthStore.isHealthDataAvailable(), start < end else { return [] }
        let qty = HKQuantityType(id)
        let unit = Self.unit(for: id)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        return await withCheckedContinuation { (cont: CheckedContinuation<[(start: Date, min: Double?, avg: Double?, max: Double?)], Never>) in
            let q = HKStatisticsCollectionQuery(
                quantityType: qty,
                quantitySamplePredicate: predicate,
                options: options,
                anchorDate: start,
                intervalComponents: DateComponents(minute: bucketMinutes)
            )
            q.initialResultsHandler = { _, results, _ in
                var out: [(start: Date, min: Double?, avg: Double?, max: Double?)] = []
                results?.enumerateStatistics(from: start, to: end) { stat, _ in
                    let mn = stat.minimumQuantity().map { converter($0.doubleValue(for: unit)) }
                    let av = stat.averageQuantity().map { converter($0.doubleValue(for: unit)) }
                    let mx = stat.maximumQuantity().map { converter($0.doubleValue(for: unit)) }
                    out.append((start: stat.startDate, min: mn, avg: av, max: mx))
                }
                cont.resume(returning: out)
            }
            store.execute(q)
        }
    }

    /// 查指定单日的统计值（用 HKStatisticsCollectionQuery，与 dailyStatistics 同方式）。
    /// 单个 HKStatisticsQuery 对 restingHeartRate 等衍生量有时返回空，CollectionQuery 稳定。
    static func statisticsForDay(
        store: HKHealthStore,
        id: HKQuantityTypeIdentifier,
        options: HKStatisticsOptions,
        date: Date,
        converter: @escaping @Sendable (Double) -> Double
    ) async -> Double? {
        guard HKHealthStore.isHealthDataAvailable() else { return nil }
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: date)
        guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { return nil }
        let qty = HKQuantityType(id)
        let unit = Self.unit(for: id)
        let predicate = HKQuery.predicateForSamples(withStart: dayStart, end: dayEnd, options: [])
        return await withCheckedContinuation { (cont: CheckedContinuation<Double?, Never>) in
            let q = HKStatisticsCollectionQuery(
                quantityType: qty,
                quantitySamplePredicate: predicate,
                options: options,
                anchorDate: dayStart,
                intervalComponents: DateComponents(day: 1)
            )
            q.initialResultsHandler = { _, results, _ in
                var value: Double?
                results?.enumerateStatistics(from: dayStart, to: dayEnd) { stat, _ in
                    let quantity = options.contains(.cumulativeSum) ? stat.sumQuantity() : stat.averageQuantity()
                    if let quantity, value == nil {
                        value = converter(quantity.doubleValue(for: unit))
                    }
                }
                cont.resume(returning: value)
            }
            store.execute(q)
        }
    }

    /// 含今天的最近 N 天：偏移量 [0, -1, ..., -(N-1)]，0=今天。
    static func dayOffsets(inclusiveDays: Int) -> [Int] {
        guard inclusiveDays > 0 else { return [] }
        return (0..<inclusiveDays).map { -$0 }
    }

    /// 不含今天的过去 N 天：偏移量 [-1, -2, ..., -N]。
    static func dayOffsetsPastExclusive(days: Int) -> [Int] {
        guard days > 0 else { return [] }
        return (1...days).map { -$0 }
    }

    /// 今天往前第 daysAgo 天的 startOfDay，0=今天，1=昨天。
    static func dateForDaysAgo(_ daysAgo: Int) -> Date {
        let cal = Calendar.current
        let base = cal.startOfDay(for: Date())
        return cal.date(byAdding: .day, value: -daysAgo, to: base) ?? base
    }
}
