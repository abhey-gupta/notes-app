import XCTest

/// Editor menus (#126): ⋯ opens paper / template / focus; the title menu holds notebook actions.
final class EditorMenuTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launchEditor() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-sampleLibrary", "YES", "-openNotebook", "Thermodynamics", "-resetToolState", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["More"].waitForExistence(timeout: 5))
        return app
    }

    @MainActor
    func testMorePopoverChangesPaperAndTemplate() {
        let app = launchEditor()
        app.buttons["More"].tap()
        let night = app.buttons["paper.night"]
        XCTAssertTrue(night.waitForExistence(timeout: 5))
        night.tap()
        XCTAssertTrue(app.switches["keepExactColors"].waitForExistence(timeout: 2), "offered on Night")
        app.buttons["paper.white"].tap()
        XCTAssertTrue(app.switches["keepExactColors"].waitForNonExistence(timeout: 2), "Night only")
        app.buttons["template.grid"].tap()
        XCTAssertTrue(app.buttons["template.grid"].isSelected)
        XCTAssertEqual(app.buttons["More"].value as? String, "White paper, Grid")
        XCTAssertTrue(app.buttons["Focus mode"].exists)
    }

    @MainActor
    func testTitleMenuDeleteConfirmsAndReturnsToLibrary() {
        let app = launchEditor()
        app.buttons["Thermodynamics, notebook options"].tap()
        for item in ["Rename", "Move to Folder", "Duplicate"] {
            XCTAssertTrue(app.buttons[item].waitForExistence(timeout: 2), "\(item) missing")
        }
        app.buttons["Delete Notebook"].tap()
        let confirm = app.alerts.buttons["Delete"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 2))
        confirm.tap()
        XCTAssertTrue(app.buttons["newNotebook"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["cover-Thermodynamics"].waitForNonExistence(timeout: 5), "moved to the trash")
    }
}
