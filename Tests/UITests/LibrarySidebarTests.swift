import XCTest

/// Library sidebar tree (#117) on the 13" simulator (portrait ≥ 1000 pt: docked). Sample folders:
/// University › Semester 3 › Physics II, Work, Personal.
final class LibrarySidebarTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-sampleLibrary", "YES", "-resetToolState", "YES"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["librarySidebar"].waitForExistence(timeout: 5), "docked by default")
        return app
    }

    @MainActor
    func testFoldersNestAndFilterTheGrid() {
        let app = launch()
        let title = app.staticTexts["libraryTitle"]
        XCTAssertEqual(title.label, "Library")
        XCTAssertFalse(app.descendants(matching: .any)["folder-Semester 3"].exists, "folders start closed")

        app.descendants(matching: .any)["folder-University"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["folder-Semester 3"].waitForExistence(timeout: 2), "picking opens it")
        app.buttons["disclose-Semester 3"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["folder-Physics II"].waitForExistence(timeout: 2), "the chevron opens it")
        XCTAssertEqual(title.label, "University", "without picking it")
        XCTAssertEqual(title.label, "University")
        XCTAssertFalse(app.staticTexts["Continue"].exists, "Continue only on All Notebooks")

        app.descendants(matching: .any)["folder-Semester 3"].tap()
        XCTAssertTrue(app.buttons["cover-Linear Algebra"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["cover-Thermodynamics"].exists, "a subfolder's notebooks stay in the subfolder")
        XCTAssertTrue(app.buttons["sidebarNotebook-Linear Algebra"].exists, "an open folder lists its notebooks")
        XCTAssertTrue(app.descendants(matching: .any)["folder-Physics II"].exists)

        // Breadcrumb up to University; a search there reaches into subfolders.
        app.buttons["crumb-University"].tap()
        XCTAssertEqual(title.label, "University")
        let search = app.textFields["searchField"]
        search.tap()
        search.typeText("Thermo")
        XCTAssertTrue(app.buttons["cover-Thermodynamics"].waitForExistence(timeout: 2))

        app.descendants(matching: .any)["folder-All Notebooks"].tap()
        XCTAssertEqual(title.label, "Library")
    }

    @MainActor
    func testHideAndShowSidebar() {
        let app = launch()
        app.buttons["hideSidebar"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["librarySidebar"].waitForNonExistence(timeout: 2))
        app.buttons["sidebarButton"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["librarySidebar"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["sidebarButton"].exists)
    }

    @MainActor
    func testNewSubfolder() {
        let app = launch()
        app.descendants(matching: .any)["folder-Work"].press(forDuration: 1)
        app.buttons["New Subfolder"].tap()
        // iOS 27 drops the alert field's identifier.
        let alert = app.alerts["New Folder"]
        XCTAssertTrue(alert.waitForExistence(timeout: 2))
        alert.textFields.firstMatch.typeText("Q4")
        alert.buttons["Create"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["folder-Q4"].waitForExistence(timeout: 2), "parent opens to show it")
    }

    @MainActor
    func testDeleteFolderDeletesEverythingInside() {
        let app = launch()
        app.descendants(matching: .any)["folder-University"].press(forDuration: 1)
        app.buttons["Delete Folder"].tap()
        let alert = app.alerts["Delete “University”?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 2))
        XCTAssertTrue(alert.staticTexts["Its 2 folders and 2 notebooks will be deleted too. Notebooks stay in the trash for 30 days."]
            .exists)
        alert.buttons["Delete"].tap()

        XCTAssertTrue(app.descendants(matching: .any)["folder-University"].waitForNonExistence(timeout: 2))
        XCTAssertFalse(app.buttons["cover-Thermodynamics"].exists)
        XCTAssertFalse(app.buttons["cover-Linear Algebra"].exists)
        XCTAssertTrue(app.buttons["cover-Product Specs"].exists)
    }

    @MainActor
    func testDragCoverOntoFolder() {
        let app = launch()
        let work = app.descendants(matching: .any)["folder-Work"]
        XCTAssertEqual(work.value as? String, "3 notebooks")
        app.buttons["cover-Sketchbook"].press(forDuration: 1, thenDragTo: work)
        XCTAssertTrue(waitForValue(work, "4 notebooks"), "the notebook moved into Work")
        XCTAssertEqual(app.descendants(matching: .any)["folder-Personal"].value as? String, "2 notebooks")
    }

    @MainActor
    private func waitForValue(_ element: XCUIElement, _ value: String) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: 3) == .completed
    }
}
