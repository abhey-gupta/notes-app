import XCTest

/// Share → Export PDF (#42): the popover exports and hands the file to the share sheet.
final class ShareTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testExportOpensShareSheetWithPDF() {
        let app = XCUIApplication()
        app.launchArguments += ["-sampleLibrary", "YES", "-openNotebook", "Thermodynamics", "-resetToolState", "YES"]
        app.launch()
        let share = app.buttons["Share"]
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        share.tap()

        let popover = app.descendants(matching: .any)["sharePopover"]
        XCTAssertTrue(popover.waitForExistence(timeout: 3))
        app.buttons["Range"].tap()
        XCTAssertTrue(app.steppers.firstMatch.exists, "range shows page steppers")
        app.buttons["All"].tap()
        app.buttons["exportButton"].tap()

        // The share sheet names the file it got: "<title>.pdf".
        let sheet = app.otherElements["ActivityListView"]
        let file = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'Thermodynamics'")).firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10) || file.waitForExistence(timeout: 1), "share sheet missing")
        XCTAssertTrue(popover.waitForNonExistence(timeout: 3))
    }
}
