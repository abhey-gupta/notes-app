import XCTest

/// Canvas host + editor wiring (#21, #31): draw → undo → redo → persists across reopen and relaunch; page
/// indicator follows scrolling on a 100-page FixtureGen notebook; add page; the zoom transition's
/// interactive dismissal doesn't steal canvas drags. The simulator has no Pencil: `-allowFingerDrawing YES`
/// lets one finger ink (two scroll).
final class CanvasTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func canvas(_ app: XCUIApplication) -> XCUIElement {
        app.scrollViews["canvas"]
    }

    /// Waits until the canvas reports `value` for the current page ("3 strokes").
    @MainActor
    func waitForStrokes(_ value: String, in app: XCUIApplication, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "value == %@", value)
        return XCTWaiter.wait(for: [expectation(for: predicate, evaluatedWith: canvas(app))], timeout: timeout) == .completed
    }

    @MainActor
    func waitForIndicator(_ app: XCUIApplication, timeout: TimeInterval = 10, where match: @escaping (String) -> Bool) -> String? {
        let pill = app.staticTexts["pageIndicator"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pill.exists, match(pill.label) {
                return pill.label
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return pill.exists ? pill.label : nil
    }

    /// Drags one finger from `from` to `to` (normalized window points), then waits out focus mode and
    /// brings the chrome back if inking collapsed it.
    @MainActor
    func ink(in app: XCUIApplication, from: CGVector, to: CGVector) {
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: from)
        let end = window.coordinate(withNormalizedOffset: to)
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        RunLoop.current.run(until: Date().addingTimeInterval(2.5))
        let show = app.buttons["Show toolbar"]
        if show.exists {
            show.tap()
            XCTAssertTrue(app.buttons["Undo"].waitForExistence(timeout: 3))
        }
    }

    @MainActor
    private func drawStroke(in app: XCUIApplication) {
        ink(in: app, from: CGVector(dx: 0.3, dy: 0.4), to: CGVector(dx: 0.65, dy: 0.45))
    }

    @MainActor
    func testStrokeUndoRedoPersistsAcrossReopenAndRelaunch() {
        let app = XCUIApplication()
        app.launchArguments += ["-resetLibrary", "YES", "-seedNotebooks", "1", "-resetToolState", "YES", "-allowFingerDrawing", "YES"]
        app.launch()
        let cover = app.buttons["cover-Thermodynamics"]
        XCTAssertTrue(cover.waitForExistence(timeout: 15))
        cover.tap()
        XCTAssertTrue(waitForStrokes("0 strokes", in: app), "blank page 1 loads")

        drawStroke(in: app)
        XCTAssertTrue(waitForStrokes("1 stroke", in: app), "stroke committed to the document")
        XCTAssertTrue(app.buttons["Undo"].isEnabled)

        app.buttons["Undo"].tap()
        XCTAssertTrue(waitForStrokes("0 strokes", in: app), "undo removes it")
        XCTAssertTrue(app.buttons["Redo"].isEnabled)
        app.buttons["Redo"].tap()
        XCTAssertTrue(waitForStrokes("1 stroke", in: app), "redo restores it")

        app.buttons["Library"].tap()
        XCTAssertTrue(cover.waitForExistence(timeout: 5))
        cover.tap()
        XCTAssertTrue(waitForStrokes("1 stroke", in: app), "stroke survives closing the editor")
        XCTAssertFalse(app.buttons["Undo"].isEnabled, "history is per editor session")

        app.terminate()
        let relaunched = XCUIApplication()
        relaunched.launchArguments += ["-allowFingerDrawing", "YES"]
        relaunched.launch()
        let again = relaunched.buttons["cover-Thermodynamics"]
        XCTAssertTrue(again.waitForExistence(timeout: 10))
        again.tap()
        XCTAssertTrue(waitForStrokes("1 stroke", in: relaunched), "stroke survives relaunch")
    }

    @MainActor
    func testEraserRemovesStrokeAndUndoBringsItBack() {
        let app = XCUIApplication()
        app.launchArguments += ["-resetLibrary", "YES", "-seedNotebooks", "1", "-resetToolState", "YES", "-allowFingerDrawing", "YES"]
        app.launch()
        let cover = app.buttons["cover-Thermodynamics"]
        XCTAssertTrue(cover.waitForExistence(timeout: 15))
        cover.tap()
        XCTAssertTrue(waitForStrokes("0 strokes", in: app))
        drawStroke(in: app)
        XCTAssertTrue(waitForStrokes("1 stroke", in: app))

        app.buttons["Eraser"].tap()
        ink(in: app, from: CGVector(dx: 0.45, dy: 0.3), to: CGVector(dx: 0.5, dy: 0.55))
        XCTAssertTrue(waitForStrokes("0 strokes", in: app), "eraser crossing the stroke removes it")
        XCTAssertTrue(app.buttons["Pen"].isSelected, "lifting after an erase switches back to the pen")

        app.buttons["Undo"].tap()
        XCTAssertTrue(waitForStrokes("1 stroke", in: app), "one undo restores the erased stroke")
    }

    /// 100-page FixtureGen notebook (generated once per simulator; slow in Debug the first time).
    @MainActor
    func testScrollingFixtureUpdatesPageIndicator() {
        let app = XCUIApplication()
        app.launchArguments += ["-fixtureNotebook", "100", "-resetToolState", "YES"]
        app.launch()
        let cover = app.buttons["cover-Fixture 100p · seed 1"]
        XCTAssertTrue(cover.waitForExistence(timeout: 300), "fixture notebook generated")
        cover.tap()
        XCTAssertEqual(waitForIndicator(app) { $0 == "1 of 100" }, "1 of 100")

        for _ in 0 ..< 4 {
            canvas(app).swipeUp(velocity: .fast)
        }
        let label = waitForIndicator(app) { label in
            guard let page = Int(label.split(separator: " ").first ?? "") else { return false }
            return page > 2 && label.hasSuffix("of 100")
        }
        let page = label.flatMap { Int($0.split(separator: " ").first ?? "") } ?? 0
        XCTAssertGreaterThan(page, 2, "indicator follows the scroll: \(label ?? "none")")

        canvas(app).swipeDown(velocity: .fast)
        let back = waitForIndicator(app) { $0 != label && $0.hasSuffix("of 100") }
        let after = back.flatMap { Int($0.split(separator: " ").first ?? "") } ?? page
        XCTAssertLessThan(after, page, "scrolling back moves it back: \(back ?? "none")")
        XCTAssertTrue(app.buttons["Library"].exists, "still in the editor")
    }

    @MainActor
    func testAddPageAppendsAndScrollsToIt() {
        let app = XCUIApplication()
        app.launchArguments += ["-resetLibrary", "YES", "-resetToolState", "YES"]
        app.launch()
        let new = app.buttons["newNotebook"]
        XCTAssertTrue(new.waitForExistence(timeout: 10))
        new.tap()
        app.buttons["New Notebook"].tap()
        let title = app.textFields["notebookTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.typeText("Scratch")
        app.buttons["createNotebook"].tap()

        XCTAssertEqual(waitForIndicator(app) { $0 == "1 of 1" }, "1 of 1")
        let add = app.buttons["addPage"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        XCTAssertEqual(waitForIndicator(app) { $0 == "2 of 2" }, "2 of 2", "new page appended and scrolled to")

        app.buttons["Library"].tap()
        let cover = app.buttons["cover-Scratch"]
        XCTAssertTrue(cover.waitForExistence(timeout: 5))
        cover.tap()
        XCTAssertNotNil(waitForIndicator(app) { $0.hasSuffix("of 2") }, "page count persisted")
    }

    /// A pinch zooms the pages without touching their strokes, and never paints one page's ink on another
    /// (real-iPad report: after pinching, ink "drawn above" appeared on the pages below).
    @MainActor
    func testPinchKeepsPagesIntactAndPaintsNoGhostInk() {
        let app = XCUIApplication()
        app.launchArguments += ["-resetLibrary", "YES", "-resetToolState", "YES", "-allowFingerDrawing", "YES"]
        app.launch()
        let new = app.buttons["newNotebook"]
        XCTAssertTrue(new.waitForExistence(timeout: 10))
        new.tap()
        app.buttons["New Notebook"].tap()
        let title = app.textFields["notebookTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.typeText("Pinch")
        app.buttons["createNotebook"].tap()
        XCTAssertTrue(waitForStrokes("0 strokes", in: app))
        drawStroke(in: app)
        XCTAssertTrue(waitForStrokes("1 stroke", in: app), "page 1 has one stroke")

        let add = app.buttons["addPage"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        XCTAssertEqual(waitForIndicator(app) { $0 == "2 of 2" }, "2 of 2")
        XCTAssertTrue(waitForStrokes("0 strokes", in: app), "page 2 is blank")

        // Zoom out (page 1's bottom comes into view above page 2), then back in, with fingers over both pages.
        for scale in [0.5, 1.6] as [CGFloat] {
            canvas(app).pinch(withScale: scale, velocity: scale < 1 ? -1 : 1)
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            XCTAssertTrue(waitForStrokes("0 strokes", in: app), "page 2 still blank after pinch \(scale)")
            XCTAssertEqual(app.staticTexts["pageIndicator"].label, "2 of 2")
        }
        // Page 2 is blank paper: no dark pixels in its middle (the only ink is on page 1, above).
        let shot = Gray(app.windows.firstMatch.screenshot().image)
        let dark = shot.darkPixelCount(in: CGRect(x: 0.3, y: 0.45, width: 0.4, height: 0.4))
        XCTAssertLessThan(dark, 20, "ghost ink on page 2")

        app.buttons["Library"].tap()
        let cover = app.buttons["cover-Pinch"]
        XCTAssertTrue(cover.waitForExistence(timeout: 5))
        cover.tap()
        // Reopens where it was left (page 2); page 1 through the overview.
        XCTAssertEqual(waitForIndicator(app) { $0 == "2 of 2" }, "2 of 2", "reopens on the page it was left on")
        app.buttons["Pages"].tap()
        let first = app.descendants(matching: .any)["page-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        first.tap()
        XCTAssertEqual(waitForIndicator(app) { $0 == "1 of 2" }, "1 of 2")
        XCTAssertTrue(waitForStrokes("1 stroke", in: app), "page 1 unchanged by the pinch")
    }

    /// Pages expand sideways (#129): press-hold at the right page edge and drag out widens every page,
    /// the drawing area says so, and the width survives reopening the notebook.
    @MainActor
    func testSideGrabWidensPagesAndPersists() {
        let app = XCUIApplication()
        app.launchArguments += ["-resetLibrary", "YES", "-seedNotebooks", "1", "-resetToolState", "YES"]
        app.launch()
        let cover = app.buttons["cover-Thermodynamics"]
        XCTAssertTrue(cover.waitForExistence(timeout: 15))
        cover.tap()
        XCTAssertTrue(waitForStrokes("0 strokes", in: app), "blank page 1 loads")
        let drawing = app.descendants(matching: .any)["drawingArea"]
        XCTAssertFalse((drawing.value as? String)?.contains("Widened") == true)

        // At the fitted zoom the page sits 96 pt of desk from the screen's right edge.
        let window = app.windows.firstMatch
        let frame = window.frame
        let origin = window.coordinate(withNormalizedOffset: .zero)
        let edge = origin.withOffset(CGVector(dx: frame.width - 96, dy: frame.height * 0.55))
        let out = edge.withOffset(CGVector(dx: 150, dy: 0))
        edge.press(forDuration: 0.8, thenDragTo: out, withVelocity: .slow, thenHoldForDuration: 0.3)
        let widened = NSPredicate(format: "value CONTAINS %@", "Widened to")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: widened, evaluatedWith: drawing)], timeout: 10), .completed, "pages widened")
        XCTAssertEqual(app.staticTexts["pageIndicator"].label, "1 of 11")

        app.buttons["Library"].tap()
        XCTAssertTrue(cover.waitForExistence(timeout: 5))
        cover.tap()
        XCTAssertTrue(waitForStrokes("0 strokes", in: app))
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: widened, evaluatedWith: drawing)], timeout: 10), .completed, "width persisted")
    }

    /// A downward drag at the top of the notebook (finger scroll, or ink with finger drawing) must not start
    /// the zoom transition's swipe-to-dismiss.
    @MainActor
    func testDownwardDragAtTopDoesNotDismissEditor() {
        for fingerDrawing in ["NO", "YES"] {
            let app = XCUIApplication()
            app.launchArguments += ["-sampleLibrary", "YES", "-resetToolState", "YES", "-allowFingerDrawing", fingerDrawing]
            app.launch()
            let cover = app.buttons["cover-Thermodynamics"]
            XCTAssertTrue(cover.waitForExistence(timeout: 10))
            cover.tap()
            XCTAssertTrue(app.buttons["Library"].waitForExistence(timeout: 5))

            let window = app.windows.firstMatch
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            XCTAssertTrue(canvas(app).exists, "editor still up (finger drawing \(fingerDrawing))")
            let library = app.buttons["newNotebook"]
            XCTAssertFalse(library.exists && library.isHittable, "library not revealed (finger drawing \(fingerDrawing))")
            app.terminate()
        }
    }
}
