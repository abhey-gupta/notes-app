import XCTest

/// Backup to a Files folder (#174) with `-backupRoot` (no Files picker): Settings rows, the line under the
/// library title, the fresh-iPad card, Restore. Real store (`-resetLibrary`, `-seedNotebooks`).
final class BackupTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        root = FileManager.default.temporaryDirectory.appending(path: "Backup-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor
    private func launch(_ arguments: [String], backsUp: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-resetLibrary", "YES", "-resetToolState", "YES"] + arguments
        if backsUp {
            app.launchArguments += ["-backupRoot", root.path(percentEncoded: false)]
        }
        app.launch()
        XCTAssertTrue(app.buttons["newNotebook"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func openSettings(_ app: XCUIApplication) {
        app.buttons["Settings"].tap()
        // Below Gestures, Pages and Display: scroll the popover's form to it.
        let footer = app.descendants(matching: .any)["backupFooter"]
        XCTAssertTrue(app.switches["tapToUndo"].waitForExistence(timeout: 5))
        for _ in 0 ..< 3 where !footer.exists {
            app.popovers.firstMatch.swipeUp()
        }
        XCTAssertTrue(footer.waitForExistence(timeout: 3))
    }

    @MainActor
    func testSettingsAndTheLineUnderTheTitle() {
        var app = launch([], backsUp: false)
        openSettings(app)
        XCTAssertTrue(app.buttons["chooseBackupFolder"].exists, "off until a folder is chosen")
        XCTAssertFalse(app.buttons["backUpNow"].exists)
        app.terminate()

        app = launch(["-seedNotebooks", "3", "-allowFingerDrawing", "YES"])
        let catalog = root.appending(path: "library.json").path(percentEncoded: false)
        let written = expectation(for: NSPredicate { _, _ in FileManager.default.fileExists(atPath: catalog) }, evaluatedWith: nil)
        wait(for: [written], timeout: 15)
        let line = app.descendants(matching: .any)["backupStatus"]
        XCTAssertTrue(line.waitForNonExistence(timeout: 10), "nothing under the title once backed up")

        // Ink a page and leave the editor: the backup runs at once and shows under the title, then folds away.
        let cover = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'cover-'")).firstMatch
        cover.tap()
        XCTAssertTrue(app.buttons["Pen"].waitForExistence(timeout: 10))
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5))
            .press(
                forDuration: 0.05,
                thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.55)),
                withVelocity: .slow,
                thenHoldForDuration: 0.3
            )
        XCTAssertTrue(app.buttons["Undo"].waitForExistence(timeout: 3) && app.buttons["Undo"].isEnabled, "inked")
        app.buttons["Library"].tap()
        XCTAssertTrue(line.waitForExistence(timeout: 10), "the backup shows under the title")
        XCTAssertTrue(line.label.hasPrefix("Backing up") || line.label == "Backed up just now", line.label)
        XCTAssertTrue(line.waitForNonExistence(timeout: 10), "then folds away")

        openSettings(app)
        let folder = app.descendants(matching: .any)["backupFolder"]
        XCTAssertTrue(folder.exists)
        XCTAssertEqual(folder.value as? String, root.lastPathComponent)
        XCTAssertTrue(app.buttons["backUpNow"].isEnabled)
        XCTAssertTrue(app.descendants(matching: .any)["restoreBackup"].exists)
        let footer = app.descendants(matching: .any)["backupFooter"].label
        XCTAssertTrue(footer.hasPrefix("Up to date. Last backup just now · 3 notebooks"), footer)
    }

    @MainActor
    func testFreshIPadRestoresFromTheFolder() {
        var app = launch(["-seedNotebooks", "3"])
        let catalog = root.appending(path: "library.json").path(percentEncoded: false)
        let written = expectation(for: NSPredicate { _, _ in FileManager.default.fileExists(atPath: catalog) }, evaluatedWith: nil)
        wait(for: [written], timeout: 15)
        app.terminate()

        // Same folder, empty library: the card offers the backup.
        app = launch([])
        let card = app.descendants(matching: .any)["restoreCard"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["3 notebooks in \(root.lastPathComponent)"].exists)

        // Choose… → Settings › Restore; restore one, then the rest.
        app.buttons["chooseRestore"].tap()
        let restoreAll = app.buttons["restoreAll"]
        XCTAssertTrue(restoreAll.waitForExistence(timeout: 5))
        let first = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'restore-'")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        let title = String(first.identifier.dropFirst("restore-".count))
        first.tap()
        XCTAssertTrue(app.descendants(matching: .any)["restored-\(title)"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["cover-\(title)"].waitForExistence(timeout: 5), "in the library behind at once")

        restoreAll.tap()
        let restored = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'restored-'"))
        let all = expectation(for: NSPredicate(format: "count == 3"), evaluatedWith: restored)
        wait(for: [all], timeout: 15)
        XCTAssertFalse(restoreAll.isEnabled, "nothing left to restore")

        app.otherElements["PopoverDismissRegion"].tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'cover-'")).count, 3)
        XCTAssertTrue(
            app.descendants(matching: .any)["folder-University"].exists || app.descendants(matching: .any)["folder-Work"].exists,
            "folders come back"
        )
    }
}
