import XCTest

/// PDF import (#119): the + menu offers Import PDF…; the import sheet (Files picker skipped with
/// `-importSamplePDF YES`, a generated 24-page PDF) shows the pages, title, folder and size; Import opens
/// the new notebook on page 1 of 24.
final class PDFImportTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testPlusMenuOffersNewNotebookAndImportPDF() {
        let app = XCUIApplication()
        app.launchArguments += ["-resetLibrary", "YES"]
        app.launch()
        let new = app.buttons["newNotebook"]
        XCTAssertTrue(new.waitForExistence(timeout: 10))
        new.tap()
        XCTAssertTrue(app.buttons["Import PDF…"].waitForExistence(timeout: 5))
        app.buttons["New Notebook"].tap()
        XCTAssertTrue(app.textFields["notebookTitle"].waitForExistence(timeout: 5), "New Notebook still opens its sheet")
    }

    @MainActor
    func testImportSheetCreatesNotebookAndOpensPageOne() {
        let app = XCUIApplication()
        app.launchArguments += ["-resetLibrary", "YES", "-resetToolState", "YES", "-importSamplePDF", "YES"]
        app.launch()
        let title = app.textFields["pdfTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 10), "import sheet up")
        XCTAssertEqual(title.value as? String, "Lecture 4 — Thermodynamics", "title from the file name")
        XCTAssertTrue(app.staticTexts["Import PDF"].exists)
        XCTAssertTrue(app.staticTexts["+ 21 pages"].waitForExistence(timeout: 5))
        let summary = app.staticTexts["pdfSummary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertTrue(summary.label.hasPrefix("24 pages · "), summary.label)
        XCTAssertEqual(app.buttons["pdfFolder"].value as? String, "None")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "import-sheet"
        shot.lifetime = .keepAlways
        add(shot)

        app.buttons["importPDF"].tap()
        XCTAssertTrue(
            app.buttons["Lecture 4 — Thermodynamics, notebook options"].waitForExistence(timeout: 10),
            "import opens the editor"
        )
        let indicator = app.staticTexts["pageIndicator"]
        XCTAssertTrue(indicator.waitForExistence(timeout: 5))
        XCTAssertEqual(indicator.label, "1 of 24")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let page = XCTAttachment(screenshot: app.screenshot())
        page.name = "imported-page-1"
        page.lifetime = .keepAlways
        add(page)

        app.buttons["Library"].tap()
        XCTAssertTrue(app.buttons["cover-Lecture 4 — Thermodynamics"].waitForExistence(timeout: 5))
    }
}
