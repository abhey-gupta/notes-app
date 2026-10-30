import XCTest

@MainActor
extension CanvasTests {
    /// A stroke that runs from page 1 onto page 2 without lifting (#163) keeps going across the seam: each
    /// page keeps its piece, and one undo takes back both.
    func testStrokeRunsOntoTheNextPage() {
        let app = XCUIApplication()
        app.launchArguments += ["-resetLibrary", "YES", "-resetToolState", "YES", "-allowFingerDrawing", "YES"]
        app.launch()
        let new = app.buttons["newNotebook"]
        XCTAssertTrue(new.waitForExistence(timeout: 10))
        new.tap()
        app.buttons["New Notebook"].tap()
        let title = app.textFields["notebookTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.typeText("Seam")
        app.buttons["createNotebook"].tap()
        XCTAssertTrue(waitForStrokes("0 strokes", in: app))
        let addPage = app.buttons["addPage"]
        XCTAssertTrue(addPage.waitForExistence(timeout: 5))
        addPage.tap()
        XCTAssertEqual(waitForIndicator(app) { $0 == "2 of 2" }, "2 of 2")
        // Page 1's bottom edge shows under the top bar (seam ≈ 13 % down): start there, left of the toolbar.
        ink(in: app, from: CGVector(dx: 0.15, dy: 0.1), to: CGVector(dx: 0.3, dy: 0.5))
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "stroke across the seam"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertTrue(waitForStrokes("1 stroke", in: app), "the page in view keeps its piece")

        app.buttons["Pages"].tap()
        let first = app.descendants(matching: .any)["page-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        first.tap()
        XCTAssertEqual(waitForIndicator(app) { $0 == "1 of 2" }, "1 of 2")
        XCTAssertTrue(waitForStrokes("1 stroke", in: app), "so does page 1")

        app.buttons["Undo"].tap()
        XCTAssertTrue(waitForStrokes("0 strokes", in: app), "one undo takes back page 1's piece")
        app.buttons["Pages"].tap()
        let second = app.descendants(matching: .any)["page-2"]
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        second.tap()
        XCTAssertEqual(waitForIndicator(app) { $0 == "2 of 2" }, "2 of 2")
        XCTAssertTrue(waitForStrokes("0 strokes", in: app), "and page 2's: it was one step")
    }
}
