import Foundation

struct BalanceResponse: Codable {
    let isAvailable: Bool
    let balanceInfos: [BalanceInfo]

    struct BalanceInfo: Codable {
        let currency: String
        let totalBalance: String

        enum CodingKeys: String, CodingKey {
            case currency
            case totalBalance = "total_balance"
        }
    }

    enum CodingKeys: String, CodingKey {
        case isAvailable = "is_available"
        case balanceInfos = "balance_infos"
    }

    var totalCNY: Double {
        Double(balanceInfos.first(where: { $0.currency == "CNY" })?.totalBalance ?? "0") ?? 0
    }
}

enum CostTrackerError: Error {
    case networkError(Error)
    case httpError(statusCode: Int, body: String)
    case invalidResponse
}

struct PriceConfig {
    let inputPrice: Double
    let outputPrice: Double

    static let `default` = PriceConfig(inputPrice: 0.000001, outputPrice: 0.000002)

    static func load() -> PriceConfig {
        let defaults = UserDefaults.standard
        let input = defaults.double(forKey: "cost_input_price")
        let output = defaults.double(forKey: "cost_output_price")
        if input > 0 && output > 0 {
            return PriceConfig(inputPrice: input, outputPrice: output)
        }
        return .default
    }

    func save() {
        UserDefaults.standard.set(inputPrice, forKey: "cost_input_price")
        UserDefaults.standard.set(outputPrice, forKey: "cost_output_price")
    }
}

struct ReconciliationResult {
    let flagged: Bool
    let diff: Double
    let expectedDrop: Double
    let actualDrop: Double
}

final class CostTracker: @unchecked Sendable {
    private let config: PriceConfig
    private var sessionTotal: Double = 0.0
    private var allTimeTotal: Double
    private let lock = NSLock()

    /// 全局单例。所有走 LLM 的环节（对话/记录/趋势/训练）共享此实例，
    /// 确保费用统一累计到顶部费用栏。测试仍可 `CostTracker(...)` new 独立实例做隔离。
    static let shared = CostTracker()

    init(
        config: PriceConfig = .load(),
        allTimeTotal: Double? = nil
    ) {
        self.config = config
        self.allTimeTotal = allTimeTotal ?? 0.0
    }

    func setHistoryTotal(_ total: Double) {
        lock.lock(); defer { lock.unlock() }
        allTimeTotal = total
    }

    func calculateCost(usage: TokenUsage) -> Double {
        let inputCost = Double(usage.promptTokens) * config.inputPrice
        let outputCost = Double(usage.completionTokens) * config.outputPrice
        return inputCost + outputCost
    }

    func accumulate(usage: TokenUsage) -> Double {
        let cost = calculateCost(usage: usage)
        lock.lock(); defer { lock.unlock() }
        sessionTotal += cost
        return cost
    }

    func sessionCost() -> Double {
        lock.lock(); defer { lock.unlock() }
        return sessionTotal
    }

    func totalCost() -> Double {
        lock.lock(); defer { lock.unlock() }
        return allTimeTotal + sessionTotal
    }

    func reconcile(previousBalance: Double, currentBalance: Double, localSpend: Double, tolerance: Double = 0.10) -> ReconciliationResult {
        let actualDrop = previousBalance - currentBalance
        let diff = abs(actualDrop - localSpend)
        return ReconciliationResult(flagged: diff > tolerance, diff: diff, expectedDrop: localSpend, actualDrop: actualDrop)
    }

    func fetchBalance(apiKey: String, session: URLSession = .shared) async throws -> BalanceResponse {
        let url = URL(string: "https://api.deepseek.com/user/balance")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CostTrackerError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CostTrackerError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CostTrackerError.httpError(statusCode: httpResponse.statusCode, body: body)
        }

        let decoder = JSONDecoder()
        let balanceResponse: BalanceResponse
        do {
            balanceResponse = try decoder.decode(BalanceResponse.self, from: data)
        } catch {
            throw CostTrackerError.invalidResponse
        }

        return balanceResponse
    }
}
