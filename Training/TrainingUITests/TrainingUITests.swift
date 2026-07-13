import XCTest

final class TrainingUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    private func launchScenario(_ index: Int, timeout: TimeInterval = 60) {
        let app = XCUIApplication()
        app.launchArguments = ["--self-test-scenario=\(index)"]
        app.launch()

        let done = app.staticTexts["SELFTEST_DONE"]
        XCTAssertTrue(done.waitForExistence(timeout: timeout),
                      "Scenario \(index): SELFTEST_DONE not found within \(timeout)s")

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Scenario-\(index)-Complete"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor func test01_recovery()       { launchScenario(0, timeout: 90) }
    @MainActor func test02_trainingPlan()   { launchScenario(1, timeout: 90) }
    @MainActor func test03_sleep()          { launchScenario(2, timeout: 90) }
    @MainActor func test04_logSoccer()      { launchScenario(3, timeout: 45) }
    @MainActor func test05_logRunning()     { launchScenario(4, timeout: 45) }
    @MainActor func test06_activityQuery()  { launchScenario(5, timeout: 60) }
    @MainActor func test07_steps()          { launchScenario(6, timeout: 45) }
    @MainActor func test08_matchTool()      { launchScenario(7, timeout: 60) }
    @MainActor func test09_matchInjection() { launchScenario(8, timeout: 60) }
}
