import XCTest

/// #122: editor chrome follows the paper, so the toolbar and its popovers stay readable over white and Night
/// pages in either system appearance. Set `TEST_RUNNER_CHROME_SHOTS=<dir>` to save PNGs for a visual check
/// (appearance is the simulator's: `xcrun simctl ui <udid> appearance dark`).
final class ChromeContrastTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testPenPopoverOpensOverEachPaper() {
        for (title, name) in [("Thermodynamics", "white-dots"), ("Launch Plan", "night")] {
            let app = XCUIApplication()
            app.launchArguments += ["-sampleLibrary", "YES", "-openNotebook", title, "-resetToolState", "YES"]
            app.launch()
            XCTAssertTrue(app.buttons["Library"].waitForExistence(timeout: 10))
            save(app, "\(name)-toolbar")
            app.buttons["Pen"].tap()
            let popover = app.descendants(matching: .any).matching(identifier: "toolPopover").firstMatch
            XCTAssertTrue(popover.waitForExistence(timeout: 3))
            XCTAssertTrue(app.buttons["Fountain"].isHittable)
            save(app, "\(name)-pen")
            // First tap outside only dismisses the popover.
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()
            XCTAssertTrue(popover.waitForNonExistence(timeout: 3))
            app.buttons["Share"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["sharePopover"].waitForExistence(timeout: 3))
            save(app, "\(name)-share")
            app.terminate()
        }
    }

    @MainActor
    func testCompactPillOverEachPaper() {
        for (title, name) in [("Thermodynamics", "white-dots"), ("Launch Plan", "night")] {
            let app = XCUIApplication()
            app.launchArguments += ["-sampleLibrary", "YES", "-openNotebook", title, "-resetToolState", "YES", "-toolbarCompact", "YES"]
            app.launch()
            let pill = app.descendants(matching: .any).matching(identifier: "focusPill").firstMatch
            XCTAssertTrue(pill.waitForExistence(timeout: 10))
            save(app, "\(name)-pill")
            pill.tap()
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "toolbar").firstMatch.waitForExistence(timeout: 3))
            save(app, "\(name)-expanded")
            app.terminate()
        }
    }

    private func save(_ app: XCUIApplication, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["CHROME_SHOTS"] else { return }
        let tag = ProcessInfo.processInfo.environment["CHROME_TAG"] ?? "chrome"
        try? app.windows.firstMatch.screenshot().pngRepresentation.write(to: URL(filePath: dir).appending(path: "\(tag)-\(name).png"))
    }
}
