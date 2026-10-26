import XCTest

/// Editor menus (#126): ⋯ opens paper / template / focus; the title menu holds notebook actions.
final class EditorMenuTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launchEditor() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-sampleLibrary", "YES", "-openNotebook", "Thermodynamics", "-resetToolState", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["More"].waitForExistence(timeout: 5))
        return app
    }

    @MainActor
    func testMorePopoverChangesPaperAndTemplate() {
        let app = launchEditor()
        app.buttons["More"].tap()
        let night = app.buttons["paper.night"]
        XCTAssertTrue(night.waitForExistence(timeout: 5))
        night.tap()
        let exact = app.switches["keepExactColors"]
        XCTAssertTrue(exact.waitForExistence(timeout: 2))
        XCTAssertTrue(exact.isEnabled, "live on Night")
        app.buttons["paper.white"].tap()
        XCTAssertFalse(exact.isEnabled, "Night only")
        app.buttons["template.grid"].tap()
        XCTAssertTrue(app.buttons["template.grid"].isSelected)
        XCTAssertEqual(app.buttons["More"].value as? String, "White paper, Grid")
        XCTAssertTrue(app.buttons["Focus mode"].exists)
    }

    /// #122: chrome and popovers stay usable as the paper flips between light and Night. Set
    /// `TEST_RUNNER_CHROME_SHOTS=<dir>` to save screenshots for a visual check.
    @MainActor
    func testChromeFollowsPaper() {
        let app = launchEditor()
        for paper in ["white", "night"] {
            app.buttons["More"].tap()
            let option = app.buttons["paper.\(paper)"]
            XCTAssertTrue(option.waitForExistence(timeout: 5))
            option.tap()
            XCTAssertTrue(option.isSelected)
            snapshot("\(paper)-more")
            dismiss(app, "pagePopover")
            app.buttons["Pen"].tap()
            XCTAssertTrue(element(app, "toolPopover").waitForExistence(timeout: 3))
            snapshot("\(paper)-pen")
            dismiss(app, "toolPopover")
        }
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func dismiss(_ app: XCUIApplication, _ id: String) {
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()
        XCTAssertTrue(element(app, id).waitForNonExistence(timeout: 3))
    }

    private func snapshot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["CHROME_SHOTS"] else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
    }

    @MainActor
    func testTitleMenuDeleteConfirmsAndReturnsToLibrary() {
        let app = launchEditor()
        app.buttons["Thermodynamics, notebook options"].tap()
        for item in ["Rename", "Move to Folder", "Duplicate"] {
            XCTAssertTrue(app.buttons[item].waitForExistence(timeout: 2), "\(item) missing")
        }
        app.buttons["Delete Notebook"].tap()
        let confirm = app.alerts.buttons["Delete"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 2))
        confirm.tap()
        XCTAssertTrue(app.buttons["newNotebook"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["cover-Thermodynamics"].waitForNonExistence(timeout: 5), "moved to the trash")
    }
}
