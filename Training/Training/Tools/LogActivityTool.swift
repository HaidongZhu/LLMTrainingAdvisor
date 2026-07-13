import Foundation

final class LogActivityTool: HealthTool, @unchecked Sendable {
    let name = "log_activity"
    private let store: DatabaseService

    init(store: DatabaseService) {
        self.store = store
    }

    func execute(params: [String: String]) async -> String {
        guard let type = params["type"], let dateStr = params["date"] else {
            return "错误：缺少 type 或 date"
        }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let date = df.date(from: dateStr) ?? Date()
        let dur = params["duration_min"].flatMap(Double.init)
        let dist = params["distance_km"].flatMap(Double.init)
        let activity = ActivityLog(
            id: UUID(), date: date, type: type,
            durationMin: dur, distanceKm: dist,
            intensity: params["intensity"],
            notes: params["notes"],
            createdAt: Date()
        )
        do {
            try store.insertActivityLog(activity)
            return "✅ 已记录: \(dateStr) \(type)\(dur.map{" \(Int($0))分钟"} ?? "")"
        } catch {
            return "保存失败: \(error.localizedDescription)"
        }
    }
}
