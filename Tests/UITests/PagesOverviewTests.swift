import XCTest

/// Pages overview (#32): open from the Pages button, add a page with a template, drag to reorder,
/// select + delete, then undo each step; opening on a 300-page fixture stays fast.
final class PagesOverviewTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func openOverview(_ app: XCUIApplication) -> XCUIElement {
        let pages = app.buttons["Pages"]
        XCTAssertTrue(pages.waitForExistence(timeout: 10))
        pages.tap()
        let overview = app.descendants(matching: .any)["pagesOverview"]
        XCTAssertTrue(overview.waitForExistence(timeout: 5))
        return overview
    }

    /// Waits until the "N pages" header reads `count`.
    @MainActor
    private func waitForCount(_ count: Int, in app: XCUIApplication, timeout: TimeInterval = 10) -> Bool {
        let label = app.staticTexts["pagesCount"]
        let predicate = NSPredicate(format: "label == %@", count == 1 ? "1 page" : "\(count) pages")
        return XCTWaiter.wait(for: [expectation(for: predicate, evaluatedWith: label)], timeout: timeout) == .completed
    }

    /// Waits until the thumb at `number` reports `pattern` ("Cornell") as its value.
    @MainActor
    private func waitForPattern(_ pattern: String, at number: Int, in app: XCUIApplication, timeout: TimeInterval = 10) -> Bool {
        let thumb = app.descendants(matching: .any)["page-\(number)"]
        let predicate = NSPredicate(format: "value == %@", pattern)
        return XCTWaiter.wait(for: [expectation(for: predicate, evaluatedWith: thumb)], timeout: timeout) == .completed
    }

    @MainActor
    func testAddReorderDeleteUndo() {
        let app = XCUIApplication()
        app.launchArguments += ["-resetLibrary", "YES", "-seedNotebooks", "1", "-resetToolState", "YES"]
        app.launch()
        let cover = app.buttons["cover-Thermodynamics"]
        XCTAssertTrue(cover.waitForExistence(timeout: 15))
        cover.tap()
        XCTAssertTrue(app.buttons["pageIndicator"].waitForExistence(timeout: 10))

        _ = openOverview(app)
        XCTAssertTrue(waitForCount(11, in: app))
        let first = app.descendants(matching: .any)["page-1"]
        XCTAssertEqual(first.label, "Page 1 of 11, current")
        XCTAssertEqual(first.value as? String, "Dotted", "seeded Thermodynamics is dotted paper")

        // Add: Cornell after the current page (1) → page 2, which becomes current.
        app.buttons["newPage-cornell"].tap()
        XCTAssertTrue(waitForCount(12, in: app), "page inserted")
        XCTAssertTrue(waitForPattern("Cornell", at: 2, in: app))
        XCTAssertEqual(app.descendants(matching: .any)["page-2"].label, "Page 2 of 12, current")

        // Reorder: lift page 2 and drop it on page 1.
        let second = app.descendants(matching: .any)["page-2"]
        second.press(forDuration: 0.6, thenDragTo: first, withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(waitForPattern("Cornell", at: 1, in: app), "page moved to the front")
        XCTAssertTrue(waitForPattern("Dotted", at: 2, in: app))

        // Delete the blank Cornell page: no ink, so no confirmation.
        app.buttons["pagesSelect"].tap()
        first.tap()
        XCTAssertEqual(first.label, "Page 1 of 12, selected")
        let delete = app.buttons["pagesDelete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        delete.tap()
        XCTAssertTrue(waitForCount(11, in: app), "page deleted")
        XCTAssertTrue(waitForPattern("Dotted", at: 1, in: app))
        XCTAssertFalse(app.buttons["pagesDelete"].exists, "select mode ends after delete")

        // Undo walks back: delete, move, insert.
        let undo = app.buttons["Undo"]
        undo.tap()
        XCTAssertTrue(waitForCount(12, in: app), "undo restores the deleted page")
        XCTAssertTrue(waitForPattern("Cornell", at: 1, in: app))
        undo.tap()
        XCTAssertTrue(waitForPattern("Cornell", at: 2, in: app), "undo moves it back")
        undo.tap()
        XCTAssertTrue(waitForCount(11, in: app), "undo removes the inserted page")
        XCTAssertFalse(undo.isEnabled)
        app.buttons["Redo"].tap()
        XCTAssertTrue(waitForCount(12, in: app), "redo inserts again")

        // Tap a thumb: closes and scrolls there.
        app.descendants(matching: .any)["page-4"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["pagesOverview"].waitForNonExistence(timeout: 3))
        let pill = app.buttons["pageIndicator"]
        XCTAssertTrue(pill.waitForExistence(timeout: 5))
        XCTAssertEqual(pill.label, "4 of 12")
    }

    /// 300-page FixtureGen notebook (generated once per simulator; slow in Debug the first time): the
    /// overlay's first frame is measured in-app (`pages.overview` signpost) and shown as the overview's value.
    @MainActor
    func testOpensFastOn300Pages() {
        let app = XCUIApplication()
        app.launchArguments += ["-fixtureNotebook", "300", "-resetToolState", "YES"]
        app.launch()
        let cover = app.buttons["cover-Fixture 300p · seed 1"]
        XCTAssertTrue(cover.waitForExistence(timeout: 600), "fixture notebook generated")
        cover.tap()
        XCTAssertTrue(app.buttons["pageIndicator"].waitForExistence(timeout: 30))
        RunLoop.current.run(until: Date().addingTimeInterval(2))

        let overview = openOverview(app)
        XCTAssertTrue(waitForCount(300, in: app))
        let predicate = NSPredicate(format: "value ENDSWITH 'ms'")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: predicate, evaluatedWith: overview)], timeout: 5), .completed)
        let text = (overview.value as? String) ?? ""
        let ms = Double(text.replacingOccurrences(of: " ms", with: "")) ?? .infinity
        let attachment = XCTAttachment(string: "pages.overview first frame on 300 pages: \(text)")
        attachment.lifetime = .keepAlways
        add(attachment)
        // Budget is 100 ms on device (≈ 75 ms in the Debug simulator without XCUITest attached); the
        // accessibility harness roughly doubles it here, so this only catches a per-page regression.
        XCTAssertLessThan(ms, 500, "overview first frame: \(text)")
        XCTAssertEqual(app.descendants(matching: .any)["page-1"].label, "Page 1 of 300, current")
        app.buttons["pagesDone"].tap()
        XCTAssertTrue(overview.waitForNonExistence(timeout: 3))
    }
}
