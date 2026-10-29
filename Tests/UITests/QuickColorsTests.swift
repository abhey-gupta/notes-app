import XCTest

/// Quick-color editor (#125): ⌄ after the swatches edits the active tool's palette (1–5 colors).
final class QuickColorsTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testAddRemoveAndPerToolPalettes() {
        let app = XCUIApplication()
        app.launchArguments += ["-sampleLibrary", "YES", "-openNotebook", "Thermodynamics", "-resetToolState", "YES"]
        app.launch()
        let toolbar = app.descendants(matching: .any)["toolbar"]
        XCTAssertTrue(toolbar.waitForExistence(timeout: 10))
        XCTAssertTrue(toolbar.buttons["Red"].exists)

        app.buttons["editColors"].tap()
        let popover = app.descendants(matching: .any)["quickColorsPopover"]
        XCTAssertTrue(popover.waitForExistence(timeout: 3))
        XCTAssertTrue(popover.staticTexts["Pen colors"].exists)
        let add = popover.buttons["addQuickColor"]
        add.tap()
        add.tap()
        XCTAssertTrue(popover.buttons["quickColorSlot-4"].waitForExistence(timeout: 2))
        XCTAssertFalse(add.exists, "five at most")
        popover.buttons["Purple"].tap()
        XCTAssertTrue(toolbar.buttons["Purple"].waitForExistence(timeout: 2), "preset replaces the selected slot")
        for _ in 0 ..< 4 {
            popover.buttons["removeQuickColor"].tap()
        }
        XCTAssertFalse(popover.buttons["quickColorSlot-1"].exists)
        XCTAssertFalse(popover.buttons["removeQuickColor"].isEnabled, "the last one stays")

        // Dismiss, switch to the highlighter: its own palette.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).tap()
        XCTAssertTrue(popover.waitForNonExistence(timeout: 3))
        toolbar.buttons["Highlighter"].tap()
        XCTAssertTrue(toolbar.buttons["Yellow"].waitForExistence(timeout: 2))
        app.buttons["editColors"].tap()
        XCTAssertTrue(popover.waitForExistence(timeout: 3))
        XCTAssertTrue(popover.staticTexts["Highlighter colors"].exists)
        XCTAssertTrue(popover.buttons["quickColorSlot-2"].exists, "highlighter keeps its three")
    }
}
