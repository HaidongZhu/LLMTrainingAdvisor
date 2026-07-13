import HealthKit

final class RecoveryTool: HealthTool, @unchecked Sendable {
    let name = "get_recovery_score"
    private let store = HKHealthStore()

    func execute(params: [String: String]) async -> String {
        let hrvToday = await metric(.heartRateVariabilitySDNN)
        let hrvBaseline = await metricRange(.heartRateVariabilitySDNN, days: 7)
        let rhrToday = await metric(.restingHeartRate)
        let rhrBaseline = await metricRange(.restingHeartRate, days: 7)

        guard let ht = hrvToday, let hb = hrvBaseline, let rt = rhrToday, let rb = rhrBaseline else {
            return "数据不足，无法计算"
        }

        let hrvScore = max(0, min(100, 50 + ((ht - hb) / hb) / 0.30 * 50))
        let rhrScore = max(0, min(100, 50 + ((rb - rt) / rb) / 0.10 * 50))
        let score = Int(0.6 * hrvScore + 0.4 * rhrScore)
        let status = score >= 67 ? "🟢 良好" : score >= 34 ? "🟡 注意" : "🔴 警觉"

        return "\(score)/100 \(status)\nRHR: \(Int(rt)) bpm (基线 \(Int(rb)))\nHRV: \(Int(ht)) ms (基线 \(Int(hb)))"
    }

    private func metric(_ id: HKQuantityTypeIdentifier) async -> Double? {
        let cal = Calendar.current
        let today = Date()
        guard let s = cal.date(bySettingHour: 0, minute: 0, second: 0, of: today),
              let e = cal.date(bySettingHour: 23, minute: 59, second: 59, of: today) else { return nil }
        let pred = HKQuery.predicateForSamples(withStart: s, end: e, options: .strictEndDate)
        let qty = HKQuantityType(id)
        return await withCheckedContinuation { cont in
            let q = HKStatisticsQuery(quantityType: qty, quantitySamplePredicate: pred, options: .discreteAverage) { _, stats, _ in
                cont.resume(returning: stats?.averageQuantity()?.doubleValue(for: HealthDataService.unit(for: id)))
            }
            store.execute(q)
        }
    }

    private func metricRange(_ id: HKQuantityTypeIdentifier, days: Int) async -> Double? {
        let byDay = await HealthDataService.dailyStatistics(store: store, id: id, options: .discreteAverage, days: days, converter: { $0 })
        let vals = Array(byDay.values)
        return vals.isEmpty ? nil : vals.reduce(0, +) / Double(vals.count)
    }

    private func metricOnDay(id: HKQuantityTypeIdentifier, date: Date) async -> Double? {
        let cal = Calendar.current
        guard let s = cal.date(bySettingHour: 0, minute: 0, second: 0, of: date),
              let e = cal.date(bySettingHour: 23, minute: 59, second: 59, of: date) else { return nil }
        let pred = HKQuery.predicateForSamples(withStart: s, end: e, options: .strictEndDate)
        let qty = HKQuantityType(id)
        return await withCheckedContinuation { cont in
            let q = HKStatisticsQuery(quantityType: qty, quantitySamplePredicate: pred, options: .discreteAverage) { _, stats, _ in
                cont.resume(returning: stats?.averageQuantity()?.doubleValue(for: HealthDataService.unit(for: id)))
            }
            store.execute(q)
        }
    }
}
