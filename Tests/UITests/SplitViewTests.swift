import XCTest

/// Split view (#175): Open in Split View from a tab's menu brings a second pane with its own bar, the
/// divider moves between stops and closes a pane dragged into an edge, ⋯ swaps and closes, the same
/// notebook opens twice and ink drawn in one view shows in the other.
final class SplitViewTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-sampleLibrary", "YES", "-resetToolState", "YES", "-allowFingerDrawing", "YES"] + arguments
        app.launch()
        XCTAssertTrue(app.buttons["tabs"].waitForExistence(timeout: 10))
        return app
    }

    private func secondaryBar(_ app: XCUIApplication) -> XCUIElement {
        app.otherElements["editorBar-secondary"]
    }

    /// Waits until the split spring and the canvases' refit have settled.
    private func settle() {
        Thread.sleep(forTimeInterval: 0.9)
    }

    @MainActor
    func testOpenFromTabMenuSideBySideThenClose() {
        let app = launch(["-openNotebook", "Thermodynamics"])
        app.buttons["Library"].tap()
        let cover = app.buttons["cover-Product Specs"]
        XCTAssertTrue(cover.waitForExistence(timeout: 5))
        cover.tap()
        XCTAssertTrue(app.buttons["tabs"].waitForExistence(timeout: 5))

        // Long-press the chip: Open in Split View ▸ the other tab.
        app.buttons["tabs"].press(forDuration: 1)
        app.buttons["Open in Split View"].tap()
        app.buttons["Thermodynamics"].tap()
        XCTAssertTrue(secondaryBar(app).waitForExistence(timeout: 5), "the second pane has its own bar")
        settle()
        let divider = app.otherElements["splitDivider"]
        XCTAssertTrue(divider.exists)
        let window = app.windows.firstMatch.frame
        XCTAssertEqual(divider.frame.midX, window.midX, accuracy: 12, "side by side at half")
        XCTAssertGreaterThan(secondaryBar(app).frame.minX, window.midX - 2, "the new pane is on the right")
        XCTAssertEqual(app.staticTexts["pageIndicator"].label, "1 of 4", "Product Specs stays on the left")
        XCTAssertEqual(app.staticTexts["pageIndicator-secondary"].label, "1 of 11")

        // ⋯ on the right → Close This Side.
        let more = secondaryBar(app).buttons["More"]
        more.tap()
        app.buttons["Close This Side"].tap()
        settle()
        XCTAssertFalse(secondaryBar(app).exists)
        XCTAssertFalse(divider.exists)
        XCTAssertEqual(app.buttons["tabs"].value as? String, "2 tabs", "its tab stays open")
        XCTAssertEqual(app.otherElements["editorBar"].frame.width, window.width, accuracy: 1)
    }

    @MainActor
    func testDividerSnapsAndClosesAtEdge() {
        let app = launch(["-openNotebook", "Thermodynamics", "-splitNotebook", "Product Specs"])
        let divider = app.otherElements["splitDivider"]
        XCTAssertTrue(divider.waitForExistence(timeout: 5))
        let window = app.windows.firstMatch
        let width = window.frame.width
        let start = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))

        // Toward ⅓: lands on it.
        start.press(
            forDuration: 0.05,
            thenDragTo: start.withOffset(CGVector(dx: -width * 0.19, dy: 0)),
            withVelocity: .slow,
            thenHoldForDuration: 0.1
        )
        settle()
        XCTAssertEqual(divider.frame.midX, width / 3, accuracy: 12)
        XCTAssertEqual(divider.value as? String, "One third")

        // Into the right edge: the right pane closes.
        let from = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from.press(
            forDuration: 0.05,
            thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)),
            withVelocity: .fast,
            thenHoldForDuration: 0
        )
        settle()
        XCTAssertFalse(divider.exists)
        XCTAssertFalse(secondaryBar(app).exists)
        XCTAssertEqual(app.buttons["tabs"].label, "Thermodynamics", "the left pane keeps the editor")
    }

    @MainActor
    func testSwapSides() {
        let app = launch(["-openNotebook", "Thermodynamics", "-splitNotebook", "Product Specs"])
        XCTAssertTrue(secondaryBar(app).waitForExistence(timeout: 5))
        app.otherElements["editorBar"].buttons["More"].tap()
        app.buttons["Swap Sides"].tap()
        settle()
        XCTAssertEqual(app.staticTexts["pageIndicator"].label, "1 of 4", "Product Specs moved left")
        XCTAssertEqual(app.staticTexts["pageIndicator-secondary"].label, "1 of 11")
        XCTAssertTrue(app.otherElements["editorBar"].buttons["Library"].exists, "‹ moves with the left side")
        XCTAssertFalse(secondaryBar(app).buttons["Library"].exists)
    }

    @MainActor
    func testSameNotebookTwiceSharesInk() {
        let app = launch(["-openNotebook", "Thermodynamics"])
        app.buttons["tabs"].press(forDuration: 1)
        app.buttons["Open in Split View"].tap()
        app.buttons["Thermodynamics (again)"].tap()
        XCTAssertTrue(secondaryBar(app).waitForExistence(timeout: 5))
        settle()
        let canvases = app.scrollViews.matching(identifier: "canvas")
        XCTAssertEqual(canvases.count, 2)
        let left = canvases.element(boundBy: 0), right = canvases.element(boundBy: 1)
        let before = right.value as? String
        // A stroke on the left page…
        let start = left.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.7))
        start.press(
            forDuration: 0.05,
            thenDragTo: start.withOffset(CGVector(dx: 120, dy: 20)),
            withVelocity: .slow,
            thenHoldForDuration: 0.1
        )
        // …shows on the right one too.
        let shows = expectation(for: NSPredicate(format: "value != %@", before ?? ""), evaluatedWith: right)
        wait(for: [shows], timeout: 5)
        XCTAssertEqual(left.value as? String, right.value as? String)

        // One history: undo on the right takes it back on both.
        secondaryBar(app).buttons["Undo"].tap()
        let undone = expectation(for: NSPredicate(format: "value == %@", before ?? ""), evaluatedWith: left)
        wait(for: [undone], timeout: 5)
    }

    /// (Library → Open in Split View isn't here: a library context menu keeps XCUI waiting ~2 min for idle,
    /// on main too.)
    @MainActor
    func testDragTabOntoPage() {
        let app = launch(["-openNotebook", "Thermodynamics"])
        app.buttons["Library"].tap()
        let cover = app.buttons["cover-Product Specs"]
        XCTAssertTrue(cover.waitForExistence(timeout: 5))
        cover.tap()
        XCTAssertTrue(app.buttons["tabs"].waitForExistence(timeout: 5))
        settle()

        // A tab dragged onto the left half opens there.
        app.buttons["tabs"].tap()
        let tab = app.buttons["tab-Product Specs"]
        XCTAssertTrue(tab.waitForExistence(timeout: 3))
        let target = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.6))
        tab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.5, thenDragTo: target, withVelocity: .default, thenHoldForDuration: 0.8)
        // The system's drop lands a few seconds after the synthesized drag ends.
        XCTAssertTrue(secondaryBar(app).waitForExistence(timeout: 12))
        settle()
        // The showing tab dropped beside itself: the same notebook on both sides, the new view on the left.
        XCTAssertEqual(app.staticTexts["pageIndicator"].label, "1 of 4")
        XCTAssertEqual(app.staticTexts["pageIndicator-secondary"].label, "1 of 4")
        XCTAssertFalse(secondaryBar(app).buttons["Library"].exists, "‹ stays on the left")
    }
}
