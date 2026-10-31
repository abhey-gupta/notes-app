import Document
import InkModel
import Library
import Sync
import XCTest

/// Sync through a Files folder (#225) with `-syncRoot` (no Files picker): the line under the library title and
/// what lands in the folder, another device's notebook arriving, a fresh library adopting the folder. The other
/// device is a real ``SyncEngine`` in the test runner with its own library, writing into the same folder.
final class SyncTests: XCTestCase {
    private var root: URL!
    private var other: OtherDevice!

    override func setUpWithError() throws {
        continueAfterFailure = false
        root = FileManager.default.temporaryDirectory.appending(path: "Sync-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        other = OtherDevice(folder: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        other.remove()
    }

    @MainActor
    private func launch(_ arguments: [String] = [], syncs: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-resetLibrary", "YES", "-resetToolState", "YES"] + arguments
        if syncs {
            app.launchArguments += ["-syncRoot", root.path(percentEncoded: false)]
        }
        app.launch()
        XCTAssertTrue(app.buttons["newNotebook"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func openSettings(_ app: XCUIApplication) {
        app.buttons["Settings"].tap()
        // Below Gestures, Pages and Display: scroll the popover's form to it.
        let footer = app.descendants(matching: .any)["syncFooter"]
        XCTAssertTrue(app.switches["tapToUndo"].waitForExistence(timeout: 5))
        for _ in 0 ..< 3 where !footer.exists {
            app.popovers.firstMatch.swipeUp()
        }
        XCTAssertTrue(footer.waitForExistence(timeout: 3))
    }

    private func waitForFile(_ path: String, timeout: TimeInterval = 15) {
        let url = root.appending(path: path).path(percentEncoded: false)
        let exists = expectation(for: NSPredicate { _, _ in FileManager.default.fileExists(atPath: url) }, evaluatedWith: nil)
        wait(for: [exists], timeout: timeout)
    }

    @MainActor
    func testSettingsAndTheLineUnderTheTitle() {
        var app = launch(syncs: false)
        openSettings(app)
        XCTAssertTrue(app.buttons["chooseSyncFolder"].exists, "off until a folder is chosen")
        XCTAssertFalse(app.buttons["syncNow"].exists)
        app.otherElements["PopoverDismissRegion"].tap()
        XCTAssertTrue(app.buttons["chooseSyncFolderCaption"].exists, "the empty library offers the folder")
        app.terminate()

        app = launch(["-seedNotebooks", "3", "-allowFingerDrawing", "YES"])
        waitForFile(SyncLayout.format)
        let line = app.descendants(matching: .any)["syncStatus"]
        XCTAssertTrue(line.waitForNonExistence(timeout: 10), "nothing under the title once synced")

        // Ink a page and leave the editor: the pass runs at once and shows under the title, then folds away.
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
        XCTAssertTrue(line.waitForExistence(timeout: 10), "the pass shows under the title")
        XCTAssertTrue(line.label.hasPrefix("Sending") || line.label == "Synced just now", line.label)
        XCTAssertTrue(line.waitForNonExistence(timeout: 10), "then folds away")

        for directory in [SyncLayout.log, SyncLayout.blobs, SyncLayout.devices] {
            let contents = try? FileManager.default.contentsOfDirectory(atPath: root.appending(path: directory).path(percentEncoded: false))
            XCTAssertFalse(contents?.isEmpty ?? true, "\(directory)/ has files")
        }
        let strokes = FileManager.default.enumerator(atPath: root.appending(path: SyncLayout.blobs).path(percentEncoded: false))?
            .compactMap { $0 as? String }.filter { $0.hasSuffix(".strokes") } ?? []
        XCTAssertFalse(strokes.isEmpty, "the inked page's strokes are a blob")

        openSettings(app)
        let folder = app.descendants(matching: .any)["syncFolder"]
        XCTAssertEqual(folder.value as? String, root.lastPathComponent)
        XCTAssertTrue(app.buttons["syncNow"].isEnabled)
        let footer = app.descendants(matching: .any)["syncFooter"].label
        XCTAssertTrue(footer.hasPrefix("Up to date · just now"), footer)
    }

    @MainActor
    func testAnotherDevicesNotebookArrives() async throws {
        let app = launch(["-seedNotebooks", "1"])
        waitForFile(SyncLayout.format)

        try await other.create("From iPhone", pages: 2)
        try await other.engine.sync()

        openSettings(app)
        app.buttons["syncNow"].tap()
        let devices = app.descendants(matching: .any)["syncDevices"]
        XCTAssertTrue(devices.waitForExistence(timeout: 3))
        devices.tap()
        XCTAssertTrue(app.descendants(matching: .any)["device-Test iPhone"].waitForExistence(timeout: 10), "the other device is listed")
        app.otherElements["PopoverDismissRegion"].tap()
        XCTAssertTrue(app.buttons["cover-From iPhone"].waitForExistence(timeout: 15), "the other device's notebook is in the library")
    }

    @MainActor
    func testFreshLibraryAdoptsTheFolder() async throws {
        let folder = try await other.store.createFolder(named: "Physics")
        try await other.create("Thermodynamics", pages: 3, in: folder.id)
        try await other.create("Recipes", pages: 1)
        try await other.engine.sync()

        let app = launch()
        XCTAssertTrue(app.buttons["cover-Thermodynamics"].waitForExistence(timeout: 15), "adopted")
        XCTAssertTrue(app.buttons["cover-Recipes"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["folder-Physics"].exists, "with its folder")
    }
}

/// Another device on the folder: its own library in a temp directory and an engine on the same folder.
private final class OtherDevice: Sendable {
    let root: URL
    let store: LibraryStore
    let engine: SyncEngine

    init(folder: URL) {
        root = FileManager.default.temporaryDirectory.appending(path: "SyncTests-other-\(UUID().uuidString)", directoryHint: .isDirectory)
        store = LibraryStore(locations: LibraryLocations(root: root))
        engine = SyncEngine(
            folder: .url(folder),
            fileSystem: CoordinatedFileSystem(root: folder),
            library: store,
            device: DeviceIdentity(id: UUID().uuidString, name: "Test iPhone", model: "iPhone"),
            stateURL: store.locations.libraryDirectory.appending(path: SyncState.fileName)
        )
    }

    func create(_ title: String, pages: Int, in folder: FolderID? = nil) async throws {
        try await store.create(Notebook(title: title, cover: .navy, paper: .dotted, pages: (0 ..< pages).map { _ in PageID() }), in: folder)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
