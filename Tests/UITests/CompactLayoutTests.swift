import XCTest

/// Compact chrome (#118), on iPhone: folders sheet, editor bottom bar, share in ⋯.
final class CompactLayoutTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "compact chrome runs on iPhone")
    }

    @MainActor
    func testFoldersSheetPicksAFolder() {
        let app = XCUIApplication()
        app.launchArguments += ["-sampleLibrary", "YES", "-resetToolState", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["cover-Thermodynamics"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["sidebar-all"].exists, "no sidebar beside the covers")

        app.buttons["sidebarToggle"].tap()
        XCTAssertTrue(app.buttons["closeFolders"].waitForExistence(timeout: 3))
        app.buttons["sidebar-Semester 3"].tap()
        XCTAssertTrue(app.buttons["closeFolders"].waitForNonExistence(timeout: 3), "picking a folder closes the sheet")
        XCTAssertTrue(app.buttons["cover-Linear Algebra"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["cover-Product Specs"].exists)

        app.buttons["sidebarToggle"].tap()
        app.buttons["closeFolders"].tap()
        XCTAssertTrue(app.buttons["closeFolders"].waitForNonExistence(timeout: 3))
    }

    @MainActor
    func testEditorBottomBarAndShareInMore() {
        let app = XCUIApplication()
        app.launchArguments += ["-sampleLibrary", "YES", "-resetToolState", "YES", "-openNotebook", "Thermodynamics"]
        app.launch()
        XCTAssertTrue(app.buttons["Library"].waitForExistence(timeout: 10))

        let toolbar = app.descendants(matching: .any).matching(identifier: "toolbar").firstMatch
        XCTAssertTrue(toolbar.waitForExistence(timeout: 3))
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(toolbar.frame.minY, window.midY, "tools sit at the bottom")
        for label in ["Pen", "Highlighter", "Eraser", "Lasso", "Undo"] {
            XCTAssertTrue(toolbar.buttons[label].exists, label)
        }
        XCTAssertFalse(app.buttons["Redo"].exists, "redo is the three-finger tap")
        XCTAssertFalse(app.buttons["Share"].exists, "share moved into ⋯")

        app.buttons["More"].tap()
        let share = app.buttons["shareRow"]
        XCTAssertTrue(share.waitForExistence(timeout: 3))
        share.tap()
        XCTAssertTrue(app.descendants(matching: .any)["sharePopover"].waitForExistence(timeout: 3), "share popover opens from ⋯")
    }
}
