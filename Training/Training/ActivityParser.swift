import Foundation

struct ActivityParser {
    private static let typePatterns: [(String, [String])] = [
        ("Soccer", ["足球", "踢球", "比赛", "踢"]),
        ("Running", ["跑步", "慢跑", "跑"]),
        ("Cycling", ["骑行", "骑车", "自行车", "骑"]),
        ("Stairs", ["楼梯", "爬楼"]),
        ("Hiking", ["徒步", "爬山", "登山", "爬", "山"]),
        ("Strength", ["力量", "举铁", "练腿"]),
        ("Swimming", ["游泳"]),
        ("Yoga", ["瑜伽"]),
    ]

    private static let intensityMap: [(String, String)] = [
        ("高强度", "high"),
        ("吃力", "high"),
        ("轻松", "easy"),
        ("刚好", "medium"),
        ("中等", "medium"),
    ]

    private static let durationPattern = try! NSRegularExpression(
        pattern: #"(\d+)\s*分钟|(\d+)\s*小时|(\d+)\s*h|(\d+)\s*min"#
    )

    private static let distancePattern = try! NSRegularExpression(
        pattern: #"(\d+(?:\.\d+)?)\s*公里|(\d+(?:\.\d+)?)\s*km|(\d+(?:\.\d+)?)\s*米"#
    )

    static func parse(_ message: String) -> ActivityLog? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard let activityType = detectActivityType(in: trimmed) else {
            return nil
        }

        let duration = extractDuration(from: trimmed)
        let distance = extractDistance(from: trimmed)
        let intensity = extractIntensity(from: trimmed)

        return ActivityLog(
            id: UUID(),
            date: Date(),
            type: activityType,
            durationMin: duration,
            distanceKm: distance,
            intensity: intensity,
            notes: nil,
            createdAt: Date()
        )
    }

    private static func detectActivityType(in message: String) -> String? {
        for (type, keywords) in typePatterns {
            for keyword in keywords {
                if message.contains(keyword) {
                    return type
                }
            }
        }
        return nil
    }

    private static func extractDuration(from message: String) -> Double? {
        let range = NSRange(message.startIndex..., in: message)
        guard let match = durationPattern.firstMatch(in: message, range: range) else {
            return nil
        }

        let nsString = message as NSString
        for i in 1...match.numberOfRanges - 1 {
            let range = match.range(at: i)
            if range.location != NSNotFound, let value = Double(nsString.substring(with: range)) {
                switch i {
                case 2:
                    return value * 60
                case 3:
                    return value * 60
                default:
                    return value
                }
            }
        }
        return nil
    }

    private static func extractDistance(from message: String) -> Double? {
        let range = NSRange(message.startIndex..., in: message)
        guard let match = distancePattern.firstMatch(in: message, range: range) else {
            return nil
        }

        let nsString = message as NSString
        for i in 1...match.numberOfRanges - 1 {
            let range = match.range(at: i)
            if range.location != NSNotFound, let value = Double(nsString.substring(with: range)) {
                if i == 3 {
                    return value / 1000
                }
                return value
            }
        }
        return nil
    }

    private static func extractIntensity(from message: String) -> String? {
        for (keyword, value) in intensityMap {
            if message.contains(keyword) {
                return value
            }
        }
        return nil
    }
}
