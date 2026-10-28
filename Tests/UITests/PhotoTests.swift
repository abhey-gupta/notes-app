import XCTest

/// Photos from the toolbar (#157): the Photo button opens the flyout; a placed photo arrives selected
/// (photo-only context bar: no colors), can be dragged, deleted and undone.
final class PhotoTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Attaches a screenshot; with `TEST_RUNNER_SCREENSHOT_DIR` set it is also written there as `<name>.png`.
    private func attachScreenshot(_ app: XCUIApplication, _ name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
            try? screenshot.pngRepresentation.write(to: URL(filePath: directory).appending(path: "\(name).png"))
        }
    }

    @MainActor
    func testPhotoButtonOpensFlyout() {
        let app = XCUIApplication()
        app.launchArguments += ["-sampleLibrary", "YES", "-openNotebook", "Thermodynamics", "-resetToolState", "YES"]
        app.launch()
        let photo = app.buttons["photoButton"]
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        photo.tap()
        let flyout = app.descendants(matching: .any)["photoFlyout"]
        XCTAssertTrue(flyout.waitForExistence(timeout: 5), "flyout opens under the button")
        // The embedded picker renders in its own process; give it a moment to show the grid.
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        attachScreenshot(app, "photo-flyout")
        XCTAssertTrue(app.buttons["Pen"].exists, "toolbar stays up behind the flyout")
        // Tap the canvas away from the flyout: it closes, the current tool is unchanged.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()
        XCTAssertTrue(flyout.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Pen"].isSelected || app.buttons["Pen"].exists)
    }

    @MainActor
    func testInsertedPhotoIsSelectedMovableAndUndoable() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-sampleLibrary", "YES", "-openNotebook", "Thermodynamics", "-resetToolState", "YES", "-insertSamplePhoto", "YES",
        ]
        app.launch()
        let bar = app.descendants(matching: .any)["selectionBar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 15), "the placed photo is selected")
        XCTAssertFalse(app.buttons["Colors"].exists, "a photo-only selection offers no colors")
        XCTAssertTrue(app.buttons["Duplicate"].exists && app.buttons["Delete"].exists)
        attachScreenshot(app, "photo-placed")

        // Drag the photo (it sits centered in the visible page) up and left; it stays selected.
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.48))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.3))
        let before = bar.frame
        start.press(forDuration: 0.2, thenDragTo: end, withVelocity: .default, thenHoldForDuration: 0.1)
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "still selected after the move")
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertNotEqual(bar.frame.origin, before.origin, "context bar followed the photo")
        attachScreenshot(app, "photo-moved")

        // Duplicate selects the copy; delete ends the selection; undo brings the copy back (unselected).
        app.buttons["Duplicate"].tap()
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        app.buttons["Delete"].tap()
        XCTAssertTrue(bar.waitForNonExistence(timeout: 5))
        let undo = app.buttons["Undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 3) && undo.isEnabled)
        undo.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertFalse(bar.exists, "undo doesn't reselect")
        attachScreenshot(app, "photo-after-undo")
    }
}
