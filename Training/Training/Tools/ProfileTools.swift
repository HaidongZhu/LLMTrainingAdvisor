import Foundation

final class ManualActivitiesTool: HealthTool, @unchecked Sendable {
    let name = "get_manual_activities"
    private let store: DatabaseService

    init(store: DatabaseService) {
        self.store = store
    }

    func execute(params: [String: String]) async -> String {
        let range = Int(params["range"] ?? "") // nil = no limit
        var rows = ["| 日期 | 类型 | 时长 | 距离 | 强度 | 备注 |"]
        let logs = (try? store.queryAllActivities()) ?? []
        let cutoff: Date? = range.flatMap { Calendar.current.date(byAdding: .day, value: -$0, to: Date()) }
        let typeFilter = params["type"]?.lowercased()
        for log in logs {
            if let cutoff, log.date < cutoff { continue }
            if let typeFilter, log.type.lowercased() != typeFilter { continue }
            let dur = log.durationMin.map { "\(Int($0))m" } ?? "—"
            let dist = log.distanceKm.map { "\(String(format: "%.1f", $0))km" } ?? "—"
            rows.append("| \(ds(log.date)) | \(log.type) | \(dur) | \(dist) | \(log.intensity ?? "—") | \(log.notes ?? "") |")
        }
        return rows.count > 1 ? rows.joined(separator: "\n") : "无手动记录"
    }

    private func ds(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "MM-dd"; return f.string(from: d) }
}

final class UserProfileTool: HealthTool, @unchecked Sendable {
    let name = "get_user_profile"
    private let store: DatabaseService

    init(store: DatabaseService) {
        self.store = store
    }

    func execute(params: [String: String]) async -> String {
        let stored = (try? store.queryAllUserProfiles()) ?? []
        if stored.isEmpty { return "暂无用户画像" }
        return stored.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
    }
}

final class SetUserProfileTool: HealthTool, @unchecked Sendable {
    let name = "set_user_profile"
    private let store: DatabaseService

    init(store: DatabaseService) {
        self.store = store
    }

    func execute(params: [String: String]) async -> String {
        var updated: [String] = []
        for (key, value) in params {
            if key == "call_id" || key == "name" { continue }
            do {
                try store.setUserProfile(key: key, value: value)
                updated.append("\(key): \(value)")
            } catch {
                return "写入失败: \(error.localizedDescription)"
            }
        }
        guard !updated.isEmpty else { return "未提供任何字段" }
        return "已更新用户画像:\n" + updated.joined(separator: "\n")
    }
}
