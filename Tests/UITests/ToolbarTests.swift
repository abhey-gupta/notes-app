import XCTest

/// Dynamic toolbar (#26): drag to each dock, pinch to compact, tap to expand, persistence, quick colors.
final class ToolbarTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(reset: Bool = true, _ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-sampleLibrary", "YES", "-openNotebook", "Thermodynamics"] + arguments
        if reset {
            app.launchArguments += ["-resetToolState", "YES"]
        }
        app.launch()
        XCTAssertTrue(app.buttons["Library"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func toolbar(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "toolbar").firstMatch
    }

    @MainActor
    private func pill(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "focusPill").firstMatch
    }

    /// Drags `element` from its centre to a normalized point of the window.
    @MainActor
    private func drag(_ element: XCUIElement, in app: XCUIApplication, to point: CGVector) {
        let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = app.windows.firstMatch.coordinate(withNormalizedOffset: point)
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .default, thenHoldForDuration: 0.1)
    }

    private enum Dock: CaseIterable {
        case top, bottom, left, right

        /// Where to drop the toolbar to dock here.
        var dropPoint: CGVector {
            switch self {
            case .top: CGVector(dx: 0.5, dy: 0.04)
            case .bottom: CGVector(dx: 0.5, dy: 0.96)
            case .left: CGVector(dx: 0.03, dy: 0.5)
            case .right: CGVector(dx: 0.97, dy: 0.5)
            }
        }

        func contains(_ frame: CGRect, in window: CGRect) -> Bool {
            let edge: CGFloat = 130
            switch self {
            case .top: return frame.width > frame.height && frame.minY < window.minY + edge
            case .bottom: return frame.width > frame.height && frame.maxY > window.maxY - edge
            case .left: return frame.height > frame.width && frame.minX < window.minX + edge
            case .right: return frame.height > frame.width && frame.maxX > window.maxX - edge
            }
        }
    }

    /// Waits until `element` rests at `dock`: inside the dock region and unchanged between two polls (the
    /// spring has settled, so later gestures hit where it actually is).
    @MainActor
    private func waitUntil(_ element: XCUIElement, isAt dock: Dock, in app: XCUIApplication, timeout: TimeInterval = 6) -> Bool {
        let window = app.windows.firstMatch.frame
        let deadline = Date().addingTimeInterval(timeout)
        var last: CGRect?
        while Date() < deadline {
            let frame = element.exists ? element.frame : nil
            if let frame, dock.contains(frame, in: window), frame == last {
                return true
            }
            last = frame
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return false
    }

    @MainActor
    func testDragSnapsToEveryDock() {
        let app = launch()
        let bar = toolbar(app)
        XCTAssertTrue(waitUntil(bar, isAt: .top, in: app), "starts docked top")

        for dock in [Dock.left, .bottom, .right, .top] {
            drag(bar, in: app, to: dock.dropPoint)
            XCTAssertTrue(waitUntil(bar, isAt: dock, in: app), "should dock \(dock), frame \(bar.frame)")
        }
        XCTAssertTrue(app.buttons["Pen"].isSelected, "dragging from a button must not trigger it")
        XCTAssertTrue(app.buttons["Black"].isSelected)
    }

    @MainActor
    func testShortDragSpringsBack() {
        let app = launch()
        let bar = toolbar(app)
        drag(bar, in: app, to: CGVector(dx: 0.5, dy: 0.12))
        XCTAssertTrue(waitUntil(bar, isAt: .top, in: app))
    }

    @MainActor
    func testPinchCompactsAndTapExpands() {
        let app = launch()
        let bar = toolbar(app)
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        bar.pinch(withScale: 0.4, velocity: -1)

        XCTAssertTrue(pill(app).waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Lasso"].exists)
        XCTAssertTrue(app.buttons["Pages"].exists, "pinch compacts the tools only, not the other capsules")

        pill(app).tap()
        XCTAssertTrue(app.buttons["Lasso"].waitForExistence(timeout: 3))
        XCTAssertTrue(waitUntil(toolbar(app), isAt: .top, in: app))
    }

    @MainActor
    func testCompactPillStaysAtItsDock() {
        let app = launch(["-toolbarDock", "left"])
        let bar = toolbar(app)
        XCTAssertTrue(waitUntil(bar, isAt: .left, in: app))
        bar.pinch(withScale: 0.4, velocity: -1)
        XCTAssertTrue(waitUntil(pill(app), isAt: .left, in: app), "pill \(pill(app).frame)")

        app.buttons["Show toolbar"].tap()
        XCTAssertTrue(waitUntil(toolbar(app), isAt: .left, in: app))
    }

    @MainActor
    func testDockCompactAndToolSurviveRelaunch() {
        var app = launch()
        let bar = toolbar(app)
        app.buttons["Highlighter"].tap()
        drag(bar, in: app, to: Dock.right.dropPoint)
        XCTAssertTrue(waitUntil(bar, isAt: .right, in: app))
        bar.pinch(withScale: 0.4, velocity: -1)
        XCTAssertTrue(pill(app).waitForExistence(timeout: 3))
        // Let the debounced save land; terminate doesn't background the scene first.
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        app.terminate()

        app = launch(reset: false)
        XCTAssertTrue(waitUntil(pill(app), isAt: .right, in: app), "compact pill restored at right")
        pill(app).tap()
        XCTAssertTrue(waitUntil(toolbar(app), isAt: .right, in: app))
        XCTAssertTrue(app.buttons["Highlighter"].isSelected)
    }

    @MainActor
    func testQuickColorRecolorsPen() {
        let app = launch()
        XCTAssertTrue(app.buttons["Black"].isSelected)
        app.buttons["Blue"].tap()
        XCTAssertTrue(app.buttons["Blue"].isSelected)
        XCTAssertFalse(app.buttons["Black"].isSelected)

        app.buttons["Eraser"].tap()
        XCTAssertTrue(app.buttons["Eraser"].isSelected)
        app.buttons["Red"].tap()
        XCTAssertTrue(app.buttons["Pen"].isSelected, "a quick color picks the pen back up")
        XCTAssertTrue(app.buttons["Red"].isSelected)
    }

    // MARK: Tool options popover (#27)

    @MainActor
    private func popover(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "toolPopover").firstMatch
    }

    @MainActor
    private func dismissPopover(_ app: XCUIApplication) {
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()
        XCTAssertTrue(popover(app).waitForNonExistence(timeout: 3))
    }

    @MainActor
    func testActiveToolOpensItsOptions() {
        let app = launch()
        app.buttons["Pen"].tap()
        XCTAssertTrue(popover(app).waitForExistence(timeout: 3), "tapping the active tool opens its options")
        app.buttons["Brush"].tap()
        app.buttons["Width 5"].tap()
        XCTAssertTrue(app.buttons["Brush"].isSelected)
        XCTAssertTrue(app.buttons["Width 5"].isSelected)
        XCTAssertTrue(app.switches["pressureToggle"].exists)
        dismissPopover(app)

        app.buttons["Pen"].tap()
        XCTAssertTrue(popover(app).waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Brush"].isSelected, "settings stick")
        dismissPopover(app)

        app.buttons["Eraser"].tap()
        XCTAssertFalse(popover(app).exists, "selecting a tool doesn't open its options")
        app.buttons["Eraser"].tap()
        XCTAssertTrue(popover(app).waitForExistence(timeout: 3))
        app.buttons["Partial"].tap()
        XCTAssertTrue(app.buttons["Partial"].isSelected)
        XCTAssertTrue(app.buttons["Size 3"].exists)
        XCTAssertFalse(app.buttons["Size 4"].exists)
    }

    @MainActor
    func testOptionsOpenFromSideDockAndCompactPill() {
        let app = launch(["-toolbarDock", "right"])
        let bar = toolbar(app)
        XCTAssertTrue(waitUntil(bar, isAt: .right, in: app))
        app.buttons["Highlighter"].tap()
        app.buttons["Highlighter"].tap()
        XCTAssertTrue(popover(app).waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Width 3"].exists)
        XCTAssertFalse(app.buttons["Width 4"].exists, "highlighter has 3 widths")
        XCTAssertLessThan(popover(app).frame.maxX, bar.frame.minX + 1, "opens beside a right-docked toolbar")
        dismissPopover(app)

        bar.pinch(withScale: 0.4, velocity: -1)
        XCTAssertTrue(waitUntil(pill(app), isAt: .right, in: app))
        app.buttons["Current tool"].tap()
        XCTAssertTrue(popover(app).waitForExistence(timeout: 3), "the pill's tool opens options without expanding")
        XCTAssertTrue(pill(app).exists)
    }

    @MainActor
    func testLongPressStoresPenColorInQuickSlot() {
        let app = launch()
        app.buttons["Pen"].tap()
        XCTAssertTrue(popover(app).waitForExistence(timeout: 3))
        app.buttons["Green"].tap()
        dismissPopover(app)
        XCTAssertFalse(app.buttons["Red"].isSelected)

        app.buttons["Red"].press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["Custom color"].waitForExistence(timeout: 2), "slot 3 now holds the green")
        XCTAssertTrue(app.buttons["Custom color"].isSelected)
    }
}
