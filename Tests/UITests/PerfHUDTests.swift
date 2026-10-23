import XCTest

final class PerfHUDTests: XCTestCase {
    @MainActor
    func testLaunchArgumentShowsHUD() {
        let app = XCUIApplication()
        app.launchArguments += ["-perfHUD", "YES"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["perfHUD"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testThreeFingerTripleTapTogglesHUD() {
        let app = XCUIApplication()
        app.launch()
        let hud = app.descendants(matching: .any)["perfHUD"]
        XCTAssertTrue(app.staticTexts["Library"].waitForExistence(timeout: 5))
        XCTAssertFalse(hud.exists)

        app.staticTexts["Library"].tap(withNumberOfTaps: 3, numberOfTouches: 3)
        XCTAssertTrue(hud.waitForExistence(timeout: 2))

        app.staticTexts["Library"].tap(withNumberOfTaps: 3, numberOfTouches: 3)
        XCTAssertTrue(hud.waitForNonExistence(timeout: 2))
    }
}
