import XCTest

/// Editor tabs and the fixed bar (#191): opening notebooks from the library adds tabs, the chip unfolds the
/// strip, switching swaps the canvas, × closes, the last close returns to the library, a page touch folds
/// the strip.
final class TabsTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(reset: Bool = true, _ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-sampleLibrary", "YES"] + arguments
        if reset {
            app.launchArguments += ["-resetToolState", "YES"]
        }
        app.launch()
        return app
    }

    @MainActor
    private func openFromLibrary(_ app: XCUIApplication, _ title: String) {
        let cover = app.buttons["cover-\(title)"]
        XCTAssertTrue(cover.waitForExistence(timeout: 5))
        cover.tap()
        XCTAssertTrue(app.buttons["tabs"].waitForExistence(timeout: 5), "the editor shows the tabs chip")
        XCTAssertEqual(app.buttons["tabs"].label, title, "\(title) is the showing tab")
    }

    /// Taps the chip and waits for the strip.
    @MainActor
    private func unfold(_ app: XCUIApplication) {
        app.buttons["tabs"].tap()
        XCTAssertTrue(app.buttons["closeTab"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testOpeningSwitchingAndClosingTabs() {
        let app = launch(["-openNotebook", "Thermodynamics"])
        let chip = app.buttons["tabs"]
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        XCTAssertEqual(chip.label, "Thermodynamics")
        XCTAssertEqual(chip.value as? String, "1 tab")
        XCTAssertEqual(app.buttons["Pages"].value as? String, "1 of 11")
        XCTAssertEqual(app.staticTexts["pageIndicator"].label, "1 of 11", "the counter lives in the bar")

        app.buttons["Library"].tap()
        XCTAssertTrue(app.buttons["cover-Thermodynamics"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Open · 11 pages"].exists, "open notebooks say so in the library")
        openFromLibrary(app, "Product Specs")
        XCTAssertEqual(chip.value as? String, "2 tabs")

        unfold(app)
        XCTAssertFalse(app.buttons["Pages"].exists, "the strip takes the bar")
        XCTAssertTrue(app.buttons["tab-Product Specs"].isSelected)
        XCTAssertFalse(app.buttons["tab-Thermodynamics"].isSelected)
        app.buttons["tab-Thermodynamics"].tap()
        XCTAssertTrue(app.buttons["Pages"].waitForExistence(timeout: 3), "picking a tab folds the strip")
        XCTAssertEqual(chip.label, "Thermodynamics")
        XCTAssertEqual(app.buttons["More"].value as? String, "Thermodynamics")
        XCTAssertEqual(app.buttons["Pages"].value as? String, "1 of 11")

        unfold(app)
        app.buttons["closeTab"].tap()
        XCTAssertTrue(app.buttons["tab-Thermodynamics"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.buttons["tab-Product Specs"].isSelected, "closing the showing tab shows its neighbour")
        app.buttons["closeTab"].tap()
        XCTAssertTrue(app.buttons["cover-Thermodynamics"].waitForExistence(timeout: 5), "no tabs left: back to the library")
        XCTAssertFalse(app.staticTexts["Open · 11 pages"].exists)
    }

    @MainActor
    func testPageTouchFoldsTheStrip() {
        let app = launch(["-openNotebook", "Thermodynamics"])
        XCTAssertTrue(app.buttons["tabs"].waitForExistence(timeout: 10))
        unfold(app)
        XCTAssertTrue(app.buttons["addTab"].exists)
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()
        XCTAssertTrue(app.buttons["Pages"].waitForExistence(timeout: 3), "a touch on the page folds the strip")
        XCTAssertFalse(app.buttons["addTab"].exists)
        unfold(app)
        app.buttons["tab-Thermodynamics"].tap()
        XCTAssertTrue(app.buttons["Pages"].waitForExistence(timeout: 3), "tapping the showing tab folds it too")
    }

    @MainActor
    func testStripScrollsWithManyTabs() {
        let app = launch()
        for title in ["Thermodynamics", "Product Specs", "Studio Journal", "Launch Plan", "Sketchbook"] {
            openFromLibrary(app, title)
            app.buttons["Library"].tap()
        }
        openFromLibrary(app, "Thermodynamics")
        XCTAssertEqual(app.buttons["tabs"].value as? String, "5 tabs")
        unfold(app)
        XCTAssertTrue(app.buttons["tab-Thermodynamics"].isSelected)
        let last = app.buttons["tab-Sketchbook"]
        XCTAssertTrue(last.exists, "every tab is in the strip")
        if !last.isHittable {
            app.descendants(matching: .any)["tabStrip"].swipeLeft()
        }
        last.tap()
        XCTAssertTrue(app.buttons["Pages"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["tabs"].label, "Sketchbook")
    }

    @MainActor
    func testFocusModeHidesBarAndShowsPagePill() {
        let app = launch(["-openNotebook", "Thermodynamics"])
        let toolbar = app.descendants(matching: .any).matching(identifier: "toolbar").firstMatch
        XCTAssertTrue(toolbar.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["editorBar"].exists)
        toolbar.pinch(withScale: 0.4, velocity: -1)
        XCTAssertTrue(app.descendants(matching: .any)["focusPill"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["editorBar"].waitForNonExistence(timeout: 3), "focus mode hides the bar")
        XCTAssertTrue(app.staticTexts["pageIndicator"].exists, "the page pill stands in for the counter")
        XCTAssertFalse(app.buttons["Pages"].exists)
        app.buttons["Show toolbar"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["editorBar"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Pages"].exists)
    }

    @MainActor
    func testHideStatusBarSetting() {
        let app = launch()
        app.openSettings()
        let toggle = app.switches["hidesStatusBar"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        let wasOn = toggle.value as? String == "1"
        toggle.switches.firstMatch.tap()
        XCTAssertEqual(toggle.value as? String, wasOn ? "0" : "1")
        toggle.switches.firstMatch.tap()
        XCTAssertEqual(toggle.value as? String, wasOn ? "1" : "0", "back to how it was")
    }

    @MainActor
    func testSettingsFromTheEditorMenu() {
        let app = launch(["-openNotebook", "Thermodynamics"])
        let more = app.buttons["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.switches["tapToUndo"].waitForExistence(timeout: 5), "back in the library, Settings showing")
        XCTAssertFalse(more.exists, "the editor has gone")
        app.closeSettings()
        XCTAssertTrue(app.buttons["cover-Thermodynamics"].waitForExistence(timeout: 5), "the notebooks again")
    }
}
