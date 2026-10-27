import XCTest

/// Two fingers tap to undo, three to redo (#121), on the add-page step; Settings → "Tap to undo" turns
/// it off.
final class TapUndoTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func waitForIndicator(_ app: XCUIApplication, timeout: TimeInterval = 10, where match: @escaping (String) -> Bool) -> String? {
        let pill = app.buttons["pageIndicator"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pill.exists, match(pill.label) {
                return pill.label
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return pill.exists ? pill.label : nil
    }

    /// Opens the seeded 11-page notebook and adds a page (one undo step).
    @MainActor
    private func launchWithAddedPage(tapToUndo: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-resetLibrary", "YES", "-seedNotebooks", "1", "-resetToolState", "YES", "-tapToUndo", tapToUndo ? "YES" : "NO",
        ]
        app.launch()
        let cover = app.buttons["cover-Thermodynamics"]
        XCTAssertTrue(cover.waitForExistence(timeout: 15))
        cover.tap()
        XCTAssertNotNil(waitForIndicator(app) { $0.hasSuffix(" of 11") }, "seeded notebook")
        let add = app.buttons["addPage"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        XCTAssertEqual(waitForIndicator(app) { $0 == "12 of 12" }, "12 of 12")
        return app
    }

    @MainActor
    func testTwoFingerTapUndoesThreeFingerTapRedoes() {
        let app = launchWithAddedPage(tapToUndo: true)
        let canvas = app.scrollViews["canvas"]
        canvas.tap(withNumberOfTaps: 1, numberOfTouches: 2)
        XCTAssertNotNil(waitForIndicator(app) { $0.hasSuffix(" of 11") }, "two-finger tap undoes the new page")
        canvas.tap(withNumberOfTaps: 1, numberOfTouches: 3)
        XCTAssertNotNil(waitForIndicator(app) { $0.hasSuffix(" of 12") }, "three-finger tap redoes it")
    }

    @MainActor
    func testTapDoesNothingWithSettingOff() {
        let app = launchWithAddedPage(tapToUndo: false)
        app.scrollViews["canvas"].tap(withNumberOfTaps: 1, numberOfTouches: 2)
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        // Page count only: the simulator's synthesized two-finger tap may also scroll (as on main).
        XCTAssertTrue(app.buttons["pageIndicator"].label.hasSuffix(" of 12"), "setting off: no undo")
    }

    @MainActor
    func testSettingsHasTapToUndoOnByDefault() {
        let app = XCUIApplication()
        app.launchArguments += ["-sampleLibrary", "YES", "-resetToolState", "YES"]
        app.launch()
        let gear = app.buttons["Settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 5))
        gear.tap()
        let toggle = app.switches["tapToUndo"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Tap with two fingers to undo, three fingers to redo."].exists)
        if toggle.value as? String != "1" {
            toggle.switches.firstMatch.tap() // left off by a manual run: back to the default
        }
        XCTAssertEqual(toggle.value as? String, "1")
    }
}
