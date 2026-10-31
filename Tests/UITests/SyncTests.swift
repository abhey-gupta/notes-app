import Document
import InkModel
import Library
import Sync
import XCTest

/// Sync through a Files folder (#225) with `-syncRoot` (no Files picker): the line under the library title and
/// what lands in the folder, another device's notebook arriving (its card says who sent it), a fresh library
/// adopting the folder behind the adopt card, and a page the other device replaced (the conflict pill, ghost
/// ink, Keep mine, ×). The other device is a real ``SyncEngine`` in the test runner with its own library,
/// writing into the same folder.
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

    /// `-syncHoldSeconds 12`: the card tag and the adopt card outlast XCUI's polling (and a pull the folder's
    /// presenter starts before Sync Now).
    @MainActor
    private func launch(_ arguments: [String] = [], syncs: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-resetLibrary", "YES", "-resetToolState", "YES"] + arguments
        if syncs {
            app.launchArguments += ["-syncRoot", root.path(percentEncoded: false), "-syncHoldSeconds", "12"]
        }
        app.launch()
        XCTAssertTrue(app.buttons["newNotebook"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func openSettings(_ app: XCUIApplication) {
        app.openSettings()
        // Below Writing, Pages and Display: scroll the page to it.
        let footer = app.descendants(matching: .any)["syncFooter"]
        for _ in 0 ..< 3 where !footer.exists {
            app.collectionViews.firstMatch.swipeUp()
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
        app.closeSettings()
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
        app.closeSettings()
        let cover = app.buttons["cover-From iPhone"]
        XCTAssertTrue(cover.waitForExistence(timeout: 15), "the other device's notebook is in the library")
        XCTAssertTrue(waitForValue(of: cover, containing: "From Test iPhone"), "its card says who sent it")
        XCTAssertTrue(waitForValue(of: cover, containing: "From Test iPhone", absent: true, timeout: 25), "for a while")

        openSettings(app)
        let devices = app.descendants(matching: .any)["syncDevices"]
        XCTAssertTrue(devices.waitForExistence(timeout: 3))
        devices.tap()
        XCTAssertTrue(app.descendants(matching: .any)["device-Test iPhone"].waitForExistence(timeout: 10), "the other device is listed")
    }

    @MainActor
    func testFreshLibraryAdoptsTheFolder() async throws {
        let folder = try await other.store.createFolder(named: "Physics")
        try await other.create("Thermodynamics", pages: 3, in: folder.id)
        try await other.create("Recipes", pages: 1)
        for n in 1 ... 6 {
            try await other.create("Notes \(n)", pages: 4)
        }
        try await other.engine.sync()

        let app = launch()
        let card = app.descendants(matching: .any)["adoptCard"]
        XCTAssertTrue(card.waitForExistence(timeout: 15), "the adopt card shows")
        XCTAssertTrue(card.label.contains("Bringing in 8 notebooks"), card.label)
        XCTAssertTrue(card.label.contains("From Test iPhone"), card.label)
        XCTAssertTrue(app.buttons["cover-Thermodynamics"].waitForExistence(timeout: 15), "adopted")
        XCTAssertTrue(app.buttons["cover-Recipes"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["folder-Physics"].exists, "with its folder")
        XCTAssertTrue(card.waitForNonExistence(timeout: 25), "the card goes once adopt finishes")
    }

    @MainActor
    func testKeepMineBringsBackAPageAnotherDeviceReplaced() async throws {
        let (app, id) = try await replacedPage()
        let canvas = app.scrollViews["canvas"]
        app.buttons["keepMine"].tap()
        XCTAssertTrue(waitForValue(of: canvas, equal: "2 strokes"), "the page shows this device's version at once, ghost gone")
        XCTAssertTrue(app.descendants(matching: .any)["conflictPill"].waitForNonExistence(timeout: 5))

        // Every device converges on it: the other device now gets this version.
        await other.engine.setOpenNotebooks([])
        var strokes = 0
        for _ in 0 ..< 30 where strokes != 2 {
            try await Task.sleep(for: .milliseconds(500))
            try await other.engine.pull()
            strokes = try await other.strokeCount(id, page: 0)
        }
        XCTAssertEqual(strokes, 2, "the folder's latest version of the page is this device's")
    }

    @MainActor
    func testDismissingAConflictKeepsTheOtherVersion() async throws {
        let (app, _) = try await replacedPage()
        let canvas = app.scrollViews["canvas"]
        app.buttons["dismissConflict"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["conflictPill"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(waitForValue(of: canvas, equal: "3 strokes"), "the other version stays, ghost gone")

        app.buttons["Library"].tap()
        app.buttons["cover-Shared"].tap()
        XCTAssertTrue(waitForValue(of: canvas, equal: "3 strokes"))
        XCTAssertFalse(app.descendants(matching: .any)["conflictPill"].exists, "let go for good")
    }

    /// The other device's notebook "Shared" (one page, one stroke) adopted here; this device adds a stroke and
    /// sends it; the other device, without taking that version, adds two strokes and sends; this device pulls.
    /// Returns with "Shared" open on that page: the pill and the ghost of this device's two strokes showing.
    @MainActor
    private func replacedPage() async throws -> (XCUIApplication, NotebookID) {
        let id = try await other.create("Shared", pages: 1)
        try await other.ink(id, page: 0)
        try await other.engine.sync()

        let app = launch(["-allowFingerDrawing", "YES"])
        let cover = app.buttons["cover-Shared"]
        XCTAssertTrue(cover.waitForExistence(timeout: 15), "adopted")
        cover.tap()
        let canvas = app.scrollViews["canvas"]
        XCTAssertTrue(waitForValue(of: canvas, equal: "1 stroke"))
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5))
            .press(
                forDuration: 0.05,
                thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.55)),
                withVelocity: .slow,
                thenHoldForDuration: 0.3
            )
        XCTAssertTrue(waitForValue(of: canvas, equal: "2 strokes"), "inked")
        if app.buttons["Show toolbar"].exists {
            app.buttons["Show toolbar"].tap()
        }
        app.buttons["Library"].tap()
        waitForEntry(besides: other.engine.device.id)

        // The other device writes the page without taking this version (its editor is open there).
        await other.engine.setOpenNotebooks([id])
        try await other.engine.pull()
        try await other.ink(id, page: 0)
        try await other.ink(id, page: 0)
        try await other.engine.push()

        openSettings(app)
        app.buttons["syncNow"].tap()
        app.closeSettings()
        XCTAssertTrue(waitForValue(of: cover, containing: "From Test iPhone"), "pulled")
        cover.tap()
        let pill = app.descendants(matching: .any)["conflictPill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 10), "the pill shows on the replaced page")
        XCTAssertEqual(app.descendants(matching: .any)["conflictMessage"].label, "Replaced by the Test iPhone version")
        XCTAssertTrue(
            waitForValue(of: canvas, equal: "3 strokes, replaced version in blue: 2 strokes"),
            "the other version shows, this device's as ghost ink"
        )
        return (app, id)
    }

    /// Waits until `element`'s value contains `text` (or, `absent`, no longer does).
    private func waitForValue(of element: XCUIElement, containing text: String, absent: Bool = false, timeout: TimeInterval = 15) -> Bool {
        let predicate = NSPredicate(format: absent ? "NOT (value CONTAINS %@)" : "value CONTAINS %@", text)
        return XCTWaiter.wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: timeout) == .completed
    }

    private func waitForValue(of element: XCUIElement, equal value: String, timeout: TimeInterval = 15) -> Bool {
        let predicate = NSPredicate(format: "value == %@", value)
        return XCTWaiter.wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: timeout) == .completed
    }

    /// Waits for a log entry from a device other than `device` (this app's push).
    private func waitForEntry(besides device: String, timeout: TimeInterval = 15) {
        let log = root.appending(path: SyncLayout.log)
        let written = expectation(for: NSPredicate { _, _ in
            let fm = FileManager.default
            let devices = (try? fm.contentsOfDirectory(atPath: log.path(percentEncoded: false))) ?? []
            return devices.contains { name in
                name != device && ((try? fm.contentsOfDirectory(atPath: log.appending(path: name).path(percentEncoded: false))) ?? [])
                    .contains { $0.hasSuffix(".json") }
            }
        }, evaluatedWith: nil)
        wait(for: [written], timeout: timeout)
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

    @discardableResult
    func create(_ title: String, pages: Int, in folder: FolderID? = nil) async throws -> NotebookID {
        try await store.create(Notebook(title: title, cover: .navy, paper: .dotted, pages: (0 ..< pages).map { _ in PageID() }), in: folder)
            .id
    }

    /// Adds a stroke to the page at `index`, checkpointed, and tells the library (as this device's editor would).
    func ink(_ id: NotebookID, page index: Int) async throws {
        var package = try await package(id)
        let page = try package.loadPage(at: index)
        let y = Float(100 + 40 * page.strokes.count)
        let stroke = Stroke(tool: .ballpoint, color: .primary, width: 2, samples: (0 ..< 8).map { Sample(x: 100 + Float($0) * 30, y: y) })
        try package.savePage(Page(
            id: page.id,
            template: page.template,
            strokes: page.strokes + [stroke],
            images: page.images,
            rev: page.rev + 1
        ))
        try await store.refresh(id)
    }

    /// Strokes on the page at `index`.
    func strokeCount(_ id: NotebookID, page index: Int) async throws -> Int {
        try await package(id).loadPage(at: index).strokes.count
    }

    private func package(_ id: NotebookID) async throws -> NotebookPackage {
        guard let entry = await store.snapshot().notebook(id) else { throw CocoaError(.fileNoSuchFile) }
        return try NotebookPackage.open(at: store.locations.packageURL(for: entry))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
