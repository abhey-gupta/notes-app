import XCTest

@MainActor
extension XCUIApplication {
    /// Settings, from the foot of the library sidebar (#228); slides the sidebar over first when it isn't docked.
    func openSettings() {
        let row = buttons["settingsRow"]
        if !row.waitForExistence(timeout: 2) {
            buttons["sidebarButton"].tap()
        }
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(switches["tapToUndo"].waitForExistence(timeout: 5), "Settings in the detail area")
    }

    /// Back to the notebooks: All Notebooks in the sidebar.
    func closeSettings() {
        let all = buttons["folder-All Notebooks"]
        if !all.waitForExistence(timeout: 2) {
            buttons["sidebarButton"].tap()
        }
        XCTAssertTrue(all.waitForExistence(timeout: 5))
        all.tap()
    }
}
