import XCTest

/// Pages overview zoom-to-cell (#124): open lands within the flight's budget, Done flies back, tapping
/// a cell flies back to that page.
final class PagesTransitionTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testOpenDoneAndTapCell() {
        let app = XCUIApplication()
        app.launchArguments += ["-resetLibrary", "YES", "-seedNotebooks", "1", "-resetToolState", "YES"]
        app.launch()
        let cover = app.buttons["cover-Thermodynamics"]
        XCTAssertTrue(cover.waitForExistence(timeout: 15))
        cover.tap()
        let pill = app.staticTexts["pageIndicator"]
        XCTAssertTrue(pill.waitForExistence(timeout: 10))
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))

        let pages = app.buttons["Pages"]
        XCTAssertTrue(pages.waitForExistence(timeout: 5))
        pages.tap()
        let overview = app.descendants(matching: .any)["pagesOverview"]
        XCTAssertTrue(overview.waitForExistence(timeout: 5))
        XCTAssertEqual(app.descendants(matching: .any)["page-1"].label, "Page 1 of 11, current")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))

        app.buttons["pagesDone"].tap()
        XCTAssertTrue(overview.waitForNonExistence(timeout: 2), "Done flies the page back within the flight")
        XCTAssertTrue(pill.waitForExistence(timeout: 2))
        XCTAssertEqual(pill.label, "1 of 11")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))

        pages.tap()
        XCTAssertTrue(overview.waitForExistence(timeout: 5))
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        app.descendants(matching: .any)["page-4"].tap()
        XCTAssertTrue(overview.waitForNonExistence(timeout: 2), "a tapped cell flies back to its page")
        XCTAssertTrue(pill.waitForExistence(timeout: 2))
        XCTAssertEqual(pill.label, "4 of 11")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
    }
}
