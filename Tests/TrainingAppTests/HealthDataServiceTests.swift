import Foundation
import HealthKit
import Testing
@testable import TrainingApp

@Suite("HealthDataService")
struct HealthDataServiceTests {

    @Test("convert exercise_minutes divides by 60")
    func convertExerciseMinutes() {
        #expect(HealthDataService.convert(780, key: "exercise_minutes") == 13.0)
    }

    @Test("convert walking_running_km divides by 1000")
    func convertWalkingRunningKm() {
        #expect(HealthDataService.convert(2880, key: "walking_running_km") == 2.88)
    }

    @Test("convert cycling_distance_km divides by 1000")
    func convertCyclingDistanceKm() {
        #expect(HealthDataService.convert(5100, key: "cycling_distance_km") == 5.1)
    }

    @Test("convert step_length_cm multiplies by 100")
    func convertStepLengthCm() {
        #expect(HealthDataService.convert(0.606, key: "step_length_cm") == 60.6)
    }

    @Test("convert resting_heart_rate passthrough")
    func convertRestingHeartRatePassthrough() {
        #expect(HealthDataService.convert(55, key: "resting_heart_rate") == 55)
    }

    @Test("convert steps passthrough")
    func convertStepsPassthrough() {
        #expect(HealthDataService.convert(12345, key: "steps") == 12345)
    }

    @Test("sleepStage InBed")
    func sleepStageInBed() {
        #expect(HealthDataService.sleepStage(0) == "InBed")
    }

    @Test("sleepStage Asleep")
    func sleepStageAsleep() {
        #expect(HealthDataService.sleepStage(1) == "Asleep")
    }

    @Test("sleepStage Awake")
    func sleepStageAwake() {
        #expect(HealthDataService.sleepStage(2) == "Awake")
    }

    @Test("sleepStage Core")
    func sleepStageCore() {
        #expect(HealthDataService.sleepStage(3) == "Core")
    }

    @Test("sleepStage Deep")
    func sleepStageDeep() {
        #expect(HealthDataService.sleepStage(4) == "Deep")
    }

    @Test("sleepStage REM")
    func sleepStageREM() {
        #expect(HealthDataService.sleepStage(5) == "REM")
    }

    @Test("sleepStage unknown returns Unk")
    func sleepStageUnknown() {
        #expect(HealthDataService.sleepStage(99) == "Unk")
    }

    @Test("woType running")
    func woTypeRunning() {
        #expect(HealthDataService.woType(.running) == "Running")
    }

    @Test("woType soccer")
    func woTypeSoccer() {
        #expect(HealthDataService.woType(.soccer) == "Soccer")
    }

    @Test("woType cycling")
    func woTypeCycling() {
        #expect(HealthDataService.woType(.cycling) == "Cycling")
    }

    @Test("woType walking")
    func woTypeWalking() {
        #expect(HealthDataService.woType(.walking) == "Walking")
    }

    @Test("woType hiking")
    func woTypeHiking() {
        #expect(HealthDataService.woType(.hiking) == "Hiking")
    }

    @Test("woType stairs")
    func woTypeStairs() {
        #expect(HealthDataService.woType(.stairs) == "Stairs")
    }

    @Test("woType unknown defaults to Other")
    func woTypeUnknown() {
        #expect(HealthDataService.woType(.badminton) == "Other")
    }

    @Test("ts formats date as yyyy-MM-dd HH:mm:ss")
    func tsDateFormat() {
        let cal = Calendar.current
        var comps = DateComponents()
        comps.year = 2026; comps.month = 7; comps.day = 6
        comps.hour = 14; comps.minute = 30; comps.second = 0
        let date = cal.date(from: comps)!

        let result = HealthDataService.ts(date)
        #expect(result == "2026-07-06 14:30:00")
    }
}
