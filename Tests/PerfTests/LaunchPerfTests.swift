import XCTest

/// Launch, open and memory over fixture libraries (ARCHITECTURE.md §11–§12), gated by `scripts/perf-gate.sh`
/// against `baselines.json`. Relative regression signal only; absolute budgets are verified on device.
///
/// Every test does one unmeasured warm-up run first (library build, dyld/disk caches), then
/// `PERF_ITERATIONS` measured runs (default 5; the gate passes `TEST_RUNNER_PERF_ITERATIONS`).
final class LaunchPerfTests: XCTestCase {
    private static let subsystem = "com.abhey.notespace"
    private static let timeout: TimeInterval = 60

    override func setUp() {
        continueAfterFailure = false
    }

    /// Process launch → app responsive, 200 notebooks.
    @MainActor
    func testColdLaunch() throws {
        let app = try makeApp(notebooks: 200)
        warmUp(app)
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: Self.options) {
            app.launch()
        }
    }

    /// `launch.firstFrame` (App.init → library's first frame), 200 notebooks.
    @MainActor
    func testLaunchToLibraryFirstFrame() throws {
        let app = try makeApp(notebooks: 200)
        warmUp(app)
        let metric = XCTOSSignpostMetric(subsystem: Self.subsystem, category: "launch", name: "launch.firstFrame")
        measure(metrics: [metric], options: Self.options) {
            app.launch()
            XCTAssertTrue(app.buttons[PerfLibrary.largeFixtureCover].waitForExistence(timeout: Self.timeout))
        }
    }

    /// `notebook.open` (cover tap → editor appears) on the 100-page fixture.
    @MainActor
    func testOpenNotebook() throws {
        let app = try makeApp(notebooks: 200)
        warmUp(app)
        let cover = app.buttons[PerfLibrary.largeFixtureCover]
        let editor = app.buttons["pageIndicator"]
        let open = {
            cover.tap()
            XCTAssertTrue(editor.waitForExistence(timeout: Self.timeout))
            app.buttons["Library"].tap()
            XCTAssertTrue(cover.waitForExistence(timeout: Self.timeout))
        }
        open() // warm-up: first editor open
        let metric = XCTOSSignpostMetric(subsystem: Self.subsystem, category: "notebook", name: "notebook.open")
        measure(metrics: [metric], options: Self.options, block: open)
    }

    /// Resident memory with 1 000 notebooks: launch, then scroll the library.
    @MainActor
    func testLibraryMemory() throws {
        let app = try makeApp(notebooks: 1000)
        warmUp(app)
        measure(metrics: [XCTMemoryMetric(application: app)], options: Self.options) {
            app.launch()
            XCTAssertTrue(app.buttons[PerfLibrary.largeFixtureCover].waitForExistence(timeout: Self.timeout))
            app.swipeUp(velocity: .fast)
            app.swipeUp(velocity: .fast)
        }
    }

    // MARK: Helpers

    private static var options: XCTMeasureOptions {
        let options = XCTMeasureOptions()
        let env = ProcessInfo.processInfo.environment["PERF_ITERATIONS"]
        options.iterationCount = env.flatMap(Int.init).map { max(1, $0) } ?? 5
        return options
    }

    @MainActor
    private func makeApp(notebooks: Int) throws -> XCUIApplication {
        let library = PerfLibrary(notebooks: notebooks)
        try library.prepare()
        let app = XCUIApplication()
        app.launchArguments += library.launchArguments
        return app
    }

    /// Unmeasured launch that waits for the library: fills caches and fails fast if fixtures are missing.
    @MainActor
    private func warmUp(_ app: XCUIApplication) {
        app.launch()
        XCTAssertTrue(app.buttons[PerfLibrary.largeFixtureCover].waitForExistence(timeout: Self.timeout), "fixture library not shown")
    }
}
