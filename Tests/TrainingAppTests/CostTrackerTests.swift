import Foundation
import Testing
@testable import TrainingApp

@Suite("CostTracker", .serialized)
struct CostTrackerTests {

    // MARK: - Cost Calculation

    @Test("calculate cost from TokenUsage with prompt and completion tokens")
    func testCalculateCostWithTokenUsage() {
        let config = PriceConfig(inputPrice: 0.000001, outputPrice: 0.000002)
        let tracker = CostTracker(config: config)
        let usage = TokenUsage(promptTokens: 1500, completionTokens: 500, totalTokens: 2000)

        let cost = tracker.calculateCost(usage: usage)

        let expected = Double(1500) * 0.000001 + Double(500) * 0.000002
        #expect(cost == expected)
    }

    @Test("calculate cost returns 0 for zero tokens")
    func testCalculateCostWithZeroTokens() {
        let config = PriceConfig(inputPrice: 0.000001, outputPrice: 0.000002)
        let tracker = CostTracker(config: config)
        let usage = TokenUsage(promptTokens: 0, completionTokens: 0, totalTokens: 0)

        let cost = tracker.calculateCost(usage: usage)

        #expect(cost == 0.0)
    }

    // MARK: - Session Accumulation

    @Test("session total accumulates correctly across multiple calls")
    func testSessionAccumulation() {
        let config = PriceConfig(inputPrice: 0.000001, outputPrice: 0.000002)
        let tracker = CostTracker(config: config)

        let usage1 = TokenUsage(promptTokens: 1000, completionTokens: 200, totalTokens: 1200)
        let usage2 = TokenUsage(promptTokens: 500, completionTokens: 300, totalTokens: 800)
        let usage3 = TokenUsage(promptTokens: 2000, completionTokens: 1000, totalTokens: 3000)

        _ = tracker.accumulate(usage: usage1)
        _ = tracker.accumulate(usage: usage2)
        _ = tracker.accumulate(usage: usage3)

        let expected = Double(1000 + 500 + 2000) * 0.000001 + Double(200 + 300 + 1000) * 0.000002
        #expect(tracker.sessionCost() == expected)
    }

    // MARK: - Default Prices

    @Test("default prices are reasonable positive values")
    func testDefaultPrices() {
        let config = PriceConfig.default

        #expect(config.inputPrice > 0)
        #expect(config.outputPrice > 0)
    }

    // MARK: - Reconciliation

    @Test("reconciliation with diff under ¥0.10 returns no warning")
    func testReconciliationWithinThreshold() {
        let tracker = CostTracker(config: .default)
        let result = tracker.reconcile(previousBalance: 10.00, currentBalance: 9.85, localSpend: 0.20)
        #expect(result.flagged == false)
        #expect(abs(result.diff - 0.05) < 0.000001)
    }

    @Test("reconciliation with diff over ¥0.10 returns warning flag")
    func testReconciliationOverThreshold() {
        let tracker = CostTracker(config: .default)
        let result = tracker.reconcile(previousBalance: 10.00, currentBalance: 9.65, localSpend: 0.20)
        #expect(result.flagged == true)
        #expect(abs(result.diff - 0.15) < 0.000001)
    }

    // MARK: - Total Cost

    @Test("totalCost includes allTimeTotal plus session accumulation")
    func testTotalCostIncludesAllTimeAndSession() {
        let config = PriceConfig.default
        let tracker = CostTracker(config: config, allTimeTotal: 100.0)

        _ = tracker.accumulate(usage: TokenUsage(promptTokens: 1_000_000, completionTokens: 0, totalTokens: 1_000_000))

        #expect(tracker.totalCost() == 100.0 + tracker.sessionCost())
    }

    // MARK: - PriceConfig

    @Test("PriceConfig load returns default when no saved values")
    func testPriceConfigLoadReturnsDefault() {
        UserDefaults.standard.removeObject(forKey: "cost_input_price")
        UserDefaults.standard.removeObject(forKey: "cost_output_price")

        let config = PriceConfig.load()

        #expect(config.inputPrice == PriceConfig.default.inputPrice)
        #expect(config.outputPrice == PriceConfig.default.outputPrice)
    }

    @Test("PriceConfig save and load roundtrip")
    func testPriceConfigSaveAndLoadRoundtrip() {
        let config = PriceConfig(inputPrice: 0.000003, outputPrice: 0.000005)
        config.save()

        let loaded = PriceConfig.load()

        #expect(loaded.inputPrice == 0.000003)
        #expect(loaded.outputPrice == 0.000005)

        UserDefaults.standard.removeObject(forKey: "cost_input_price")
        UserDefaults.standard.removeObject(forKey: "cost_output_price")
    }

    // MARK: - BalanceResponse Decoding

    @Test("BalanceResponse decoding from balance API JSON")
    func testBalanceResponseDecoding() throws {
        let json = """
        {
            "is_available": true,
            "balance_infos": [
                {"currency": "CNY", "total_balance": "128.35"},
                {"currency": "USD", "total_balance": "18.50"}
            ]
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let response = try decoder.decode(BalanceResponse.self, from: json)

        #expect(response.isAvailable == true)
        #expect(response.totalCNY == 128.35)
    }

    @Test("BalanceResponse totalCNY returns 0 when no CNY entry")
    func testBalanceResponseTotalCNYNoCNYEntry() throws {
        let json = """
        {
            "is_available": true,
            "balance_infos": [
                {"currency": "USD", "total_balance": "18.50"}
            ]
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let response = try decoder.decode(BalanceResponse.self, from: json)

        #expect(response.totalCNY == 0)
    }
}
