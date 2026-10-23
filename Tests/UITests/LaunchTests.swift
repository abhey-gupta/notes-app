import XCTest

final class LaunchTests: XCTestCase {
    @MainActor
    func testLaunchShowsRoot() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Notespace"].waitForExistence(timeout: 5))
    }
}
