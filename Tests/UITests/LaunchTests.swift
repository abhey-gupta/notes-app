import XCTest

/// App shell smoke (#13, #34): library → editor → back, focus mode; create → persists across relaunch.
/// Shell tests use the in-memory fixtures (`-sampleLibrary`); persistence tests use the real store.
final class LaunchTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchShowsLibrary() {
        let app = XCUIApplication()
        app.launchArguments += ["-sampleLibrary", "YES", "-resetToolState", "YES"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Library"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["cover-Thermodynamics"].exists)
        XCTAssertTrue(app.buttons["newNotebook"].exists)
    }

    @MainActor
    func testOpenNotebookShowsChromeAndBackReturns() {
        let app = XCUIApplication()
        app.launchArguments += ["-sampleLibrary", "YES", "-resetToolState", "YES"]
        app.launch()
        let cover = app.buttons["cover-Thermodynamics"]
        XCTAssertTrue(cover.waitForExistence(timeout: 5))
        cover.tap()

        let back = app.buttons["Library"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        for tool in ["Pen", "Highlighter", "Eraser", "Lasso", "Undo", "Redo", "Pages", "More"] {
            XCTAssertTrue(app.buttons[tool].exists, "\(tool) missing")
        }
        XCTAssertFalse(app.buttons["Share"].exists, "share is in ⋯")
        XCTAssertEqual(app.buttons["More"].value as? String, "Thermodynamics")
        XCTAssertEqual(app.buttons["Pages"].value as? String, "1 of 11", "the page counter sits in the bar (#191)")
        XCTAssertTrue(app.buttons["tab-Thermodynamics"].isSelected)

        back.tap()
        XCTAssertTrue(app.buttons["newNotebook"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Pen"].waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testFocusModeSurvivesInkingUntilChevron() {
        let app = XCUIApplication()
        // No Pencil in the simulator: let one finger ink.
        app.launchArguments += [
            "-sampleLibrary",
            "YES",
            "-openNotebook",
            "Thermodynamics",
            "-resetToolState",
            "YES",
            "-allowFingerDrawing",
            "YES",
            "-focusMode",
            "YES",
        ]
        app.launch()
        let pill = app.descendants(matching: .any)["focusPill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 5))

        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.55))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.6))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.5)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        app.staticTexts["pageIndicator"].tap()
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Current tool")).firstMatch.tap()

        XCTAssertTrue(pill.exists, "ink and taps don't leave focus mode (#158)")
        XCTAssertFalse(app.buttons["Lasso"].exists)

        app.buttons["Show toolbar"].tap()
        XCTAssertTrue(app.buttons["Lasso"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Undo"].isEnabled, "stroke should be undoable")
    }

    @MainActor
    func testCreatedNotebookPersistsAcrossRelaunch() {
        let app = XCUIApplication()
        app.launchArguments += ["-resetLibrary", "YES", "-resetToolState", "YES"]
        app.launch()
        let new = app.buttons["newNotebook"]
        XCTAssertTrue(new.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No notebooks yet. Tap New to start one."].exists, "fresh install shows the empty state")
        new.tap()
        app.buttons["New Notebook"].tap()

        let title = app.textFields["notebookTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.typeText("Organic Chemistry")
        app.buttons["createNotebook"].tap()

        XCTAssertTrue(app.buttons["More"].waitForExistence(timeout: 5), "create opens the editor")
        XCTAssertEqual(app.buttons["More"].value as? String, "Organic Chemistry")
        app.buttons["Library"].tap()
        XCTAssertTrue(app.buttons["cover-Organic Chemistry"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["recent-Organic Chemistry"].exists)

        app.terminate()
        let relaunched = XCUIApplication()
        relaunched.launch()
        XCTAssertTrue(relaunched.buttons["cover-Organic Chemistry"].waitForExistence(timeout: 5), "notebook survives relaunch")
        XCTAssertFalse(relaunched.staticTexts["No notebooks yet. Tap New to start one."].exists)
    }
}
