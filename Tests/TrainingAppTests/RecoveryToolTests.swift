import Foundation
import Testing
@testable import TrainingApp

@Suite("RecoveryTool")
struct RecoveryToolTests {

    @Test("recoveryScore returns 50 when today equals baseline")
    func testRecoveryScore() {
        let score = HealthDataService.recoveryScore(
            hrvToday: 30.0, hrvBaseline: 30.0,
            rhrToday: 60.0, rhrBaseline: 60.0
        )
        #expect(score == 50)
    }

    @Test("recoveryScore favors higher HRV and lower RHR")
    func testRecoveryScoreHigherHRVLowerRHR() {
        let score1 = HealthDataService.recoveryScore(
            hrvToday: 30.0, hrvBaseline: 30.0,
            rhrToday: 60.0, rhrBaseline: 60.0
        )
        let score2 = HealthDataService.recoveryScore(
            hrvToday: 39.0, hrvBaseline: 30.0,
            rhrToday: 54.0, rhrBaseline: 60.0
        )
        #expect(score2 > score1)
    }
}
