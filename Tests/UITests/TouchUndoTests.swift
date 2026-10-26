import XCTest

/// Two-finger tap undoes, three-finger tap redoes (#121); with nothing to undo or redo they do nothing.
/// `-allowFingerDrawing YES`: one finger inks, so the taps also must not leave a dot.
final class TouchUndoTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func canvas(_ app: XCUIApplication) -> XCUIElement {
        app.scrollViews["canvas"]
    }

    /// Waits until the canvas reports `value` for the current page ("3 strokes").
    @MainActor
    private func waitForStrokes(_ value: String, in app: XCUIApplication, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "value == %@", value)
        return XCTWaiter.wait(for: [expectation(for: predicate, evaluatedWith: canvas(app))], timeout: timeout) == .completed
    }

    /// One finger stroke, then waits out focus mode and brings the chrome back if inking collapsed it.
    @MainActor
    private func drawStroke(in app: XCUIApplication) {
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.4))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.45))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        RunLoop.current.run(until: Date().addingTimeInterval(2.5))
        let show = app.buttons["Show toolbar"]
        if show.exists {
            show.tap()
            XCTAssertTrue(app.buttons["Undo"].waitForExistence(timeout: 3))
        }
    }

    @MainActor
    private func tap(_ app: XCUIApplication, fingers: Int) {
        canvas(app).tap(withNumberOfTaps: 1, numberOfTouches: fingers)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
    }

    @MainActor
    func testTwoFingerTapUndoesThreeFingerTapRedoes() {
        let app = XCUIApplication()
        app.launchArguments += ["-resetLibrary", "YES", "-seedNotebooks", "1", "-resetToolState", "YES", "-allowFingerDrawing", "YES"]
        app.launch()
        let cover = app.buttons["cover-Thermodynamics"]
        XCTAssertTrue(cover.waitForExistence(timeout: 15))
        cover.tap()
        XCTAssertTrue(waitForStrokes("0 strokes", in: app), "blank page 1 loads")

        tap(app, fingers: 2)
        tap(app, fingers: 3)
        XCTAssertTrue(waitForStrokes("0 strokes", in: app), "taps with no history do nothing and don't ink")
        XCTAssertFalse(app.buttons["Undo"].isEnabled)

        drawStroke(in: app)
        XCTAssertTrue(waitForStrokes("1 stroke", in: app))

        tap(app, fingers: 2)
        XCTAssertTrue(waitForStrokes("0 strokes", in: app), "two-finger tap undoes")
        XCTAssertFalse(app.buttons["Undo"].isEnabled)
        XCTAssertTrue(app.buttons["Redo"].isEnabled)

        tap(app, fingers: 3)
        XCTAssertTrue(waitForStrokes("1 stroke", in: app), "three-finger tap redoes")
        XCTAssertTrue(app.buttons["Undo"].isEnabled)
        XCTAssertFalse(app.buttons["Redo"].isEnabled)

        tap(app, fingers: 3)
        XCTAssertTrue(waitForStrokes("1 stroke", in: app), "nothing to redo: no change")
    }
}
