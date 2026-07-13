import Foundation

struct ChatMessage: Codable, Identifiable {
    let id: UUID
    let role: String
    var content: String
    var fullRequest: String
    var tokenIn: Int
    var tokenOut: Int
    var cost: Double
    let createdAt: Date
}

struct PlannerResponse: Codable {
    let tools: [PlannedTool]
    let promptTemplate: String

    enum CodingKeys: String, CodingKey {
        case tools
        case promptTemplate = "prompt_template"
    }
}

struct ActivityLog: Codable, Identifiable {
    var id: UUID
    var date: Date
    var type: String
    var durationMin: Double?
    var distanceKm: Double?
    var intensity: String?
    var notes: String?
    var createdAt: Date
}

struct UserProfile: Codable {
    let key: String
    let value: String
}

struct TokenUsage: Codable {
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }
}

enum AppConfig {
    static let deepSeekAPIKey = Secrets.deepSeekAPIKey
    static let deepSeekModel = "deepseek-v4-pro"
    static let isSelfTestMode = false
}

struct MatchSchedule: Codable, Identifiable {
    var id: UUID
    var date: Date
    var time: String?
    var opponent: String?
    var intensity: String?
    var notes: String?
    var actualDurationMin: Double?
    var actualIntensity: String?
    var isCompleted: Bool
    var createdAt: Date
}
