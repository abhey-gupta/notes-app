import XCTest

/// Hold to snap (#165), end to end on a PencilKit canvas: a slightly slanted line held at its end commits as
/// one level line (the freehand stroke never lands), one undo removes it, and a line lifted without a hold
/// stays as drawn. The simulator has no Pencil: `-allowFingerDrawing YES` lets one finger ink.
final class ShapeSnapTests: XCTestCase {
    /// Lines run from x 0.3 to 0.65 of the window and fall 0.02 of its height (~4°, inside the 6° snap).
    private static let x0: CGFloat = 0.3
    private static let x1: CGFloat = 0.65
    private static let fall: CGFloat = 0.02

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func waitForStrokes(_ value: String, in app: XCUIApplication, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "value == %@", value)
        return XCTWaiter.wait(for: [expectation(for: predicate, evaluatedWith: app.scrollViews["canvas"])], timeout: timeout) == .completed
    }

    /// A slanted line from `y`, held still at its end for `hold` seconds before lifting.
    @MainActor
    private func drawLine(_ app: XCUIApplication, y: CGFloat, hold: TimeInterval) {
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: Self.x0, dy: y))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: Self.x1, dy: y + Self.fall))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: hold)
        RunLoop.current.run(until: Date().addingTimeInterval(2.5))
        let show = app.buttons["Show toolbar"]
        if show.exists {
            show.tap()
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
    }

    /// Ink near the line's end (x just short of ``x1``) around row `y` (normalized).
    @MainActor
    private func inkAtEnd(_ app: XCUIApplication, y: CGFloat) -> Int {
        let shot = app.windows.firstMatch.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.lifetime = .keepAlways
        add(attachment)
        let region = CGRect(x: Self.x1 - 0.04, y: y - 0.006, width: 0.03, height: 0.012)
        return Gray(shot.image).darkPixelCount(in: region)
    }

    @MainActor
    func testHeldLineSnapsLevelAndUndoesInOneStep() {
        let app = XCUIApplication()
        app.launchArguments += ["-resetLibrary", "YES", "-seedNotebooks", "1", "-resetToolState", "YES", "-allowFingerDrawing", "YES"]
        app.launch()
        let cover = app.buttons["cover-Thermodynamics"]
        XCTAssertTrue(cover.waitForExistence(timeout: 15))
        cover.tap()
        XCTAssertTrue(waitForStrokes("0 strokes", in: app), "blank page 1 loads")

        // Lifted at once: stays slanted, ending low.
        drawLine(app, y: 0.6, hold: 0.1)
        XCTAssertTrue(waitForStrokes("1 stroke", in: app))
        XCTAssertGreaterThan(inkAtEnd(app, y: 0.6 + Self.fall), 0, "an unheld line is left as drawn")
        XCTAssertEqual(inkAtEnd(app, y: 0.6), 0)

        // Held: one stroke, level with its start.
        drawLine(app, y: 0.4, hold: 1.2)
        XCTAssertTrue(waitForStrokes("2 strokes", in: app), "the shape replaces the freehand stroke")
        XCTAssertGreaterThan(inkAtEnd(app, y: 0.4), 0, "the held line snapped level")
        XCTAssertEqual(inkAtEnd(app, y: 0.4 + Self.fall), 0, "no freehand stroke left")

        app.buttons["Undo"].tap()
        XCTAssertTrue(waitForStrokes("1 stroke", in: app), "one undo removes the shape")
        XCTAssertEqual(inkAtEnd(app, y: 0.4), 0)
    }
}
