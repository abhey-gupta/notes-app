import XCTest

/// Editor tabs and the fixed bar (#191): opening notebooks from the library adds tabs, switching swaps the
/// canvas, × closes, the last close returns to the library, overflow folds into "+N", tabs survive a relaunch.
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
        XCTAssertTrue(app.buttons["tab-\(title)"].waitForExistence(timeout: 5), "\(title) becomes a tab")
        XCTAssertTrue(app.buttons["tab-\(title)"].isSelected)
    }

    @MainActor
    func testOpeningSwitchingAndClosingTabs() {
        let app = launch(["-openNotebook", "Thermodynamics"])
        XCTAssertTrue(app.buttons["tab-Thermodynamics"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["Pages"].value as? String, "1 of 11")
        XCTAssertFalse(app.staticTexts["pageIndicator"].exists, "the counter lives in the bar")

        app.buttons["Library"].tap()
        XCTAssertTrue(app.buttons["cover-Thermodynamics"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Open · 11 pages"].exists, "open notebooks say so in the library")
        openFromLibrary(app, "Product Specs")
        XCTAssertTrue(app.buttons["tab-Thermodynamics"].exists, "the first tab is still there")
        XCTAssertFalse(app.buttons["tab-Thermodynamics"].isSelected)

        app.buttons["tab-Thermodynamics"].tap()
        XCTAssertTrue(app.buttons["tab-Thermodynamics"].isSelected)
        XCTAssertEqual(app.buttons["More"].value as? String, "Thermodynamics")
        XCTAssertEqual(app.buttons["Pages"].value as? String, "1 of 11")

        app.buttons["closeTab"].tap()
        XCTAssertTrue(app.buttons["tab-Thermodynamics"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.buttons["tab-Product Specs"].isSelected, "closing the showing tab shows its neighbour")
        XCTAssertEqual(app.buttons["More"].value as? String, "Product Specs")

        app.buttons["closeTab"].tap()
        XCTAssertTrue(app.buttons["cover-Thermodynamics"].waitForExistence(timeout: 5), "no tabs left: back to the library")
        XCTAssertFalse(app.staticTexts["Open · 11 pages"].exists)
    }

    @MainActor
    func testOverflowChipListsHiddenTabs() {
        let app = launch()
        for title in ["Thermodynamics", "Product Specs", "Studio Journal", "Launch Plan", "Sketchbook"] {
            openFromLibrary(app, title)
            app.buttons["Library"].tap()
        }
        openFromLibrary(app, "Thermodynamics")
        let more = app.buttons["moreTabs"]
        if more.exists {
            XCTAssertTrue(app.buttons["tab-Thermodynamics"].isSelected, "the showing tab is never folded away")
            more.tap()
            XCTAssertTrue(app.buttons["Sketchbook"].waitForExistence(timeout: 3), "the chip lists every tab")
            app.buttons["Sketchbook"].tap()
            XCTAssertTrue(app.buttons["tab-Sketchbook"].waitForExistence(timeout: 3))
            XCTAssertTrue(app.buttons["tab-Sketchbook"].isSelected)
        } else {
            XCTAssertTrue(app.buttons["tab-Sketchbook"].exists, "a wide bar shows every tab")
        }
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
        app.buttons["Show toolbar"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["editorBar"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["pageIndicator"].waitForNonExistence(timeout: 3))
    }

    @MainActor
    func testHideStatusBarSetting() {
        let app = launch()
        let settings = app.buttons["settingsButton"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        let toggle = app.switches["hidesStatusBar"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        toggle.tap()
        XCTAssertEqual(toggle.value as? String, "1")
        toggle.tap()
        XCTAssertEqual(toggle.value as? String, "0")
    }
}
