import XCTest

/// Library sidebar (#117): folder tree navigation, breadcrumb, drag a cover onto a folder, hide/show.
final class LibrarySidebarTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-sampleLibrary", "YES", "-resetToolState", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["cover-Thermodynamics"].waitForExistence(timeout: 5))
        return app
    }

    @MainActor
    func testFolderTreeAndBreadcrumb() {
        let app = launch()
        app.buttons["sidebar-Semester 3"].tap()
        XCTAssertTrue(app.staticTexts["Semester 3"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["cover-Linear Algebra"].exists)
        XCTAssertFalse(app.buttons["cover-Product Specs"].exists, "folder shows only its own notebooks")
        XCTAssertFalse(app.buttons["recent-Thermodynamics"].exists, "Continue lives on All Notebooks only")

        app.buttons["Expand"].firstMatch.tap()
        let physics = app.buttons["sidebar-Physics II"]
        XCTAssertTrue(physics.waitForExistence(timeout: 3))
        physics.tap()
        XCTAssertTrue(app.buttons["cover-Thermodynamics"].waitForExistence(timeout: 3))

        // Breadcrumb back to the parent.
        app.buttons["crumb-Semester 3"].tap()
        XCTAssertTrue(app.buttons["cover-Linear Algebra"].waitForExistence(timeout: 3))

        app.buttons["sidebar-all"].tap()
        XCTAssertTrue(app.buttons["recent-Thermodynamics"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testDragCoverOntoFolderMovesIt() {
        let app = launch()
        let cover = app.buttons["cover-Product Specs"]
        let folder = app.buttons["sidebar-Personal"]
        cover.press(forDuration: 0.8, thenDragTo: folder, withVelocity: .slow, thenHoldForDuration: 0.5)

        folder.tap()
        XCTAssertTrue(app.buttons["cover-Product Specs"].waitForExistence(timeout: 3), "moved into Personal")
    }

    @MainActor
    func testSidebarHidesAndShows() {
        let app = launch()
        let toggle = app.buttons["sidebarToggle"]
        toggle.tap()
        XCTAssertTrue(app.buttons["sidebar-all"].waitForNonExistence(timeout: 3))
        toggle.tap()
        XCTAssertTrue(app.buttons["sidebar-all"].waitForExistence(timeout: 3))
    }
}
