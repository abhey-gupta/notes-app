import XCTest

/// Hold to erase (#211), end to end on a PencilKit canvas: a touch held still where it went down turns into the
/// eraser for the rest of the drag (its dot never lands), lifting goes back to the pen, one undo restores what it
/// erased. The simulator has no Pencil: `-allowFingerDrawing YES` lets one finger ink.
final class HoldEraseTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func waitForStrokes(_ value: String, in app: XCUIApplication, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "value == %@", value)
        return XCTWaiter.wait(for: [expectation(for: predicate, evaluatedWith: app.scrollViews["canvas"])], timeout: timeout) == .completed
    }

    /// Presses at `from` (normalized window point) for `hold` seconds, drags to `to` and lifts; then brings the
    /// chrome back if inking collapsed it.
    @MainActor
    private func drag(_ app: XCUIApplication, from: CGVector, to: CGVector, hold: TimeInterval) {
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: from)
        start.press(
            forDuration: hold,
            thenDragTo: window.coordinate(withNormalizedOffset: to),
            withVelocity: .slow,
            thenHoldForDuration: 0.1
        )
        RunLoop.current.run(until: Date().addingTimeInterval(2.5))
        let show = app.buttons["Show toolbar"]
        if show.exists {
            show.tap()
            XCTAssertTrue(app.buttons["Undo"].waitForExistence(timeout: 3))
        }
    }

    @MainActor
    func testHeldTouchErasesThenGoesBackToThePen() {
        let app = XCUIApplication()
        app.launchArguments += ["-resetLibrary", "YES", "-seedNotebooks", "1", "-resetToolState", "YES", "-allowFingerDrawing", "YES"]
        app.launch()
        let cover = app.buttons["cover-Thermodynamics"]
        XCTAssertTrue(cover.waitForExistence(timeout: 15))
        cover.tap()
        XCTAssertTrue(waitForStrokes("0 strokes", in: app), "blank page 1 loads")

        drag(app, from: CGVector(dx: 0.3, dy: 0.4), to: CGVector(dx: 0.65, dy: 0.45), hold: 0.05)
        XCTAssertTrue(waitForStrokes("1 stroke", in: app), "a quick press draws")

        drag(app, from: CGVector(dx: 0.45, dy: 0.3), to: CGVector(dx: 0.5, dy: 0.55), hold: 1.2)
        XCTAssertTrue(waitForStrokes("0 strokes", in: app), "the held drag erases the stroke and leaves no ink")
        XCTAssertTrue(app.buttons["Pen"].isSelected, "lifting goes back to the pen")

        app.buttons["Undo"].tap()
        XCTAssertTrue(waitForStrokes("1 stroke", in: app), "one undo restores the erased stroke")
    }
}
