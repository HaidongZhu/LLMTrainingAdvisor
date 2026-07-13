import Foundation

final class MatchScheduleTool: HealthTool, @unchecked Sendable {
    let name = "get_match_schedule"
    private let store: DatabaseService

    init(store: DatabaseService) {
        self.store = store
    }

    func execute(params: [String: String]) async -> String {
        let matches = (try? store.queryUpcomingMatches(limit: 5)) ?? []
        guard !matches.isEmpty else { return "无未来比赛" }
        var rows = ["| 日期 | 时间 | 对手 | 强度 |"]
        for m in matches {
            let dateStr = ds(m.date)
            let time = m.time ?? "—"
            let opp = m.opponent ?? "—"
            let intensity = m.intensity ?? "—"
            rows.append("| \(dateStr) | \(time) | \(opp) | \(intensity) |")
        }
        return rows.joined(separator: "\n")
    }

    private func ds(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MM-dd"; return f.string(from: d)
    }
}
