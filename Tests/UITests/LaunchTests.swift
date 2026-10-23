import XCTest

/// App shell smoke (#13): library → editor → back, focus mode, new notebook.
final class LaunchTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchShowsLibrary() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Library"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["cover-Thermodynamics"].exists)
        XCTAssertTrue(app.buttons["newNotebook"].exists)
    }

    @MainActor
    func testOpenNotebookShowsChromeAndBackReturns() {
        let app = XCUIApplication()
        app.launch()
        let cover = app.buttons["cover-Thermodynamics"]
        XCTAssertTrue(cover.waitForExistence(timeout: 5))
        cover.tap()

        let back = app.buttons["Library"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        for tool in ["Pen", "Highlighter", "Eraser", "Lasso", "Undo", "Redo", "Pages", "Share", "More"] {
            XCTAssertTrue(app.buttons[tool].exists, "\(tool) missing")
        }
        XCTAssertTrue(app.buttons["Thermodynamics, notebook options"].exists)
        XCTAssertTrue(app.buttons["pageIndicator"].exists)

        back.tap()
        XCTAssertTrue(app.buttons["newNotebook"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Pen"].waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testInkingCollapsesToFocusPillAndTapRestores() {
        let app = XCUIApplication()
        app.launchArguments += ["-openNotebook", "Thermodynamics"]
        app.launch()
        XCTAssertTrue(app.buttons["Pen"].waitForExistence(timeout: 5))

        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.55))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.6))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 2)

        let pill = app.descendants(matching: .any)["focusPill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Lasso"].exists)

        app.buttons["Show toolbar"].tap()
        XCTAssertTrue(app.buttons["Lasso"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Undo"].isEnabled, "stroke should be undoable")
    }

    @MainActor
    func testNewNotebookOpensEditor() {
        let app = XCUIApplication()
        app.launch()
        let new = app.buttons["newNotebook"]
        XCTAssertTrue(new.waitForExistence(timeout: 5))
        new.tap()

        let title = app.textFields["notebookTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.typeText("Organic Chemistry")
        app.buttons["createNotebook"].tap()

        XCTAssertTrue(app.buttons["Organic Chemistry, notebook options"].waitForExistence(timeout: 5))
        app.buttons["Library"].tap()
        XCTAssertTrue(app.buttons["cover-Organic Chemistry"].waitForExistence(timeout: 5))
    }
}
