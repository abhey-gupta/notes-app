import XCTest

/// Compact chrome (#118: iPhone, narrow iPad windows), forced with `-compactChrome` on the iPad simulator.
final class CompactChromeTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-sampleLibrary", "YES", "-resetToolState", "YES", "-compactChrome", "YES"] + arguments
        app.launch()
        return app
    }

    @MainActor
    func testFoldersSheetFiltersLibrary() {
        let app = launch()
        let folders = app.buttons["foldersButton"]
        XCTAssertTrue(folders.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["newFolder"].exists, "no folder chips in compact")
        folders.tap()

        let sheet = app.descendants(matching: .any)["foldersSheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 3))
        app.buttons["folder-Work"].tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Work"].waitForExistence(timeout: 2), "section shows the folder")
        XCTAssertTrue(app.buttons["cover-Product Specs"].exists)
        XCTAssertFalse(app.buttons["cover-Thermodynamics"].exists, "other folders' notebooks hidden")

        folders.tap()
        XCTAssertTrue(sheet.waitForExistence(timeout: 3))
        app.buttons["Close"].tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 3))
    }

    @MainActor
    func testSearchSwapsHeaderForField() {
        let app = launch()
        let search = app.buttons["searchButton"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        field.typeText("Studio")
        XCTAssertTrue(app.buttons["cover-Studio Journal"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["cover-Product Specs"].exists)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(search.waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["cover-Product Specs"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testEditorBottomBarAndMoreMenu() {
        let app = launch(["-openNotebook", "Thermodynamics", "-toolbarDock", "top"])
        let toolbar = app.descendants(matching: .any)["toolbar"]
        XCTAssertTrue(toolbar.waitForExistence(timeout: 5))
        // Bottom bar whatever the saved dock; photos, redo and the laser pointer move off it.
        XCTAssertGreaterThan(toolbar.frame.midY, app.windows.firstMatch.frame.midY)
        XCTAssertFalse(app.buttons["photoButton"].exists)
        XCTAssertFalse(app.buttons["Redo"].exists)
        XCTAssertTrue(toolbar.buttons["Undo"].exists)

        app.buttons["More"].tap()
        XCTAssertFalse(app.buttons["Focus mode"].exists, "no focus mode in compact")
        app.buttons["Share"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["sharePopover"].waitForExistence(timeout: 3))
    }
}
