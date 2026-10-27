import XCTest

/// Accessibility (#45): VoiceOver names/values on the chrome, the canvas as one "Drawing area", chrome that
/// grows with Dynamic Type up to AX1, and Accessibility Inspector audits on the library and the editor.
final class AccessibilityTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-sampleLibrary", "YES", "-resetToolState", "YES"] + extra
        app.launch()
        return app
    }

    @MainActor
    private func openEditor(_ app: XCUIApplication) {
        let cover = app.buttons["cover-Thermodynamics"]
        XCTAssertTrue(cover.waitForExistence(timeout: 10))
        cover.tap()
        XCTAssertTrue(app.buttons["Pen"].waitForExistence(timeout: 10))
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testLibraryAndToolbarSpeakTheirState() {
        let app = launch()
        let cover = app.buttons["cover-Thermodynamics"]
        XCTAssertTrue(cover.waitForExistence(timeout: 10))
        XCTAssertEqual(cover.label, "Thermodynamics")
        XCTAssertTrue((cover.value as? String)?.hasSuffix("pages") == true, "cover value: \(String(describing: cover.value))")
        cover.tap()

        let pen = app.buttons["Pen"]
        XCTAssertTrue(pen.waitForExistence(timeout: 10))
        XCTAssertEqual(pen.value as? String, "Ballpoint pen, Black, 0.5 mm")
        app.buttons["Blue"].tap()
        XCTAssertEqual(pen.value as? String, "Ballpoint pen, Blue, 0.5 mm", "quick color updates the pen's value")
        XCTAssertTrue(app.buttons["Blue"].isSelected)
        XCTAssertTrue(app.buttons["Undo"].exists)
        XCTAssertTrue(app.buttons["Redo"].exists)

        // The canvas is one element: page and stroke count as its value.
        let drawing = app.descendants(matching: .any)["drawingArea"]
        XCTAssertTrue(drawing.waitForExistence(timeout: 5))
        XCTAssertEqual(drawing.label, "Drawing area")
        XCTAssertTrue((drawing.value as? String)?.hasPrefix("Page 1 of ") == true, "drawing value: \(String(describing: drawing.value))")

        // Tool options: sizes are spoken in mm.
        pen.tap()
        XCTAssertTrue(app.descendants(matching: .any)["toolPopover"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Saved size 0.5 mm"].isSelected)
    }

    /// AX1: chrome text and capsules grow (buttons 1.5×) and stay on screen.
    @MainActor
    func testChromeGrowsWithDynamicType() {
        let app = launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM"])
        XCTAssertTrue(app.buttons["cover-Thermodynamics"].waitForExistence(timeout: 10))
        attachScreenshot(app, "Library AX1")
        openEditor(app)
        let window = app.windows.firstMatch.frame
        let pen = app.buttons["Pen"]
        XCTAssertGreaterThanOrEqual(pen.frame.height, 59, "tool button grows at AX1")
        for name in ["Library", "Pen", "Lasso", "Undo", "Redo", "Pages", "Share", "More", "Thermodynamics, notebook options"] {
            let frame = app.buttons[name].frame
            XCTAssertTrue(window.contains(frame), "\(name) on screen: \(frame)")
        }
        attachScreenshot(app, "Editor AX1")
        pen.tap()
        let popover = app.descendants(matching: .any)["toolPopover"]
        XCTAssertTrue(popover.waitForExistence(timeout: 3))
        XCTAssertTrue(window.contains(app.buttons["penSizePlus"].frame), "popover size controls fit")
        attachScreenshot(app, "Tool options AX1")
    }

    @MainActor
    func testLibraryPassesAccessibilityAudit() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["cover-Thermodynamics"].waitForExistence(timeout: 10))
        try audit(app)
    }

    @MainActor
    func testEditorPassesAccessibilityAudit() throws {
        let app = launch()
        openEditor(app)
        try audit(app)
    }

    /// Runs the audits and fails once, listing all issues. Dynamic Type is left out: the app caps text at AX1
    /// by design (#45), which the audit reports as "partially unsupported"; `testChromeGrowsWithDynamicType`
    /// covers it instead.
    @MainActor
    private func audit(_ app: XCUIApplication) throws {
        var issues: [String] = []
        let covers = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'cover-'")).allElementsBoundByIndex.map(\.frame)
        try app.performAccessibilityAudit(for: XCUIAccessibilityAuditType.all.subtracting(.dynamicType)) { issue in
            if issue.auditType == .contrast, let element = issue.element, Self.isSampledArt(element, covers: covers) {
                return true
            }
            let element = issue.element.map { "\($0.elementType.rawValue) '\($0.label)' id '\($0.identifier)' \($0.frame)" } ?? "-"
            issues.append("\(issue.compactDescription) [\(element)]")
            return true
        }
        XCTAssertTrue(issues.isEmpty, issues.joined(separator: "\n"))
    }

    /// Contrast the audit measures from pixels it can't read right: text on Liquid Glass (the page pill, the
    /// prominent New button) and the printed label on cover art (hidden from VoiceOver; the tile speaks the
    /// title). Their token contrast is unit-tested (`TokenTests.textMeetsAAContrast`).
    @MainActor
    private static func isSampledArt(_ element: XCUIElement, covers: [CGRect]) -> Bool {
        element.identifier == "pageIndicator" || element.label == "New" || covers.contains { $0.contains(element.frame) }
    }
}
