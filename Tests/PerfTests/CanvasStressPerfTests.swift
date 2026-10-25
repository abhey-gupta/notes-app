import FixtureGen
import XCTest

/// #44 stress pass: fling scroll + pinch 0.5×→4× on the 300-page fixture (ARCHITECTURE.md §5, §11).
///
/// Device: build Release with `PERF_FIXTURES` (`make perf-device`); the app generates the fixture in its
/// own container on first launch (`-fixtureNotebook 300`). Simulator runs work too but hitches are not
/// meaningful there.
final class CanvasStressPerfTests: XCTestCase {
    private static let subsystem = "com.abhey.notespace"
    private static let pages = 300

    override func setUp() {
        continueAfterFailure = false
    }

    /// One iteration ≈ 30 s: fling down/up and pinch out/in, repeated.
    @MainActor
    func testScrollZoomStress() {
        let app = XCUIApplication()
        app.launchArguments += ["-fixtureNotebook", "\(Self.pages)"]
        app.launch()
        let title = FixtureGenerator(FixtureSpec(pages: Self.pages)).notebook.title
        let cover = app.buttons["cover-\(title)"]
        XCTAssertTrue(cover.waitForExistence(timeout: 300), "fixture not shown")
        cover.tap()
        let canvas = app.scrollViews["canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 60))

        let options = XCTMeasureOptions()
        let env = ProcessInfo.processInfo.environment["PERF_ITERATIONS"]
        options.iterationCount = env.flatMap(Int.init).map { max(1, $0) } ?? 3
        let metrics: [XCTMetric] = [
            XCTOSSignpostMetric.scrollDecelerationMetric,
            XCTOSSignpostMetric(subsystem: Self.subsystem, category: "canvas", name: "canvas.frame"),
            XCTMemoryMetric(application: app),
        ]
        measure(metrics: metrics, options: options) {
            let start = Date()
            while Date().timeIntervalSince(start) < 30 {
                for _ in 0 ..< 3 {
                    canvas.swipeUp(velocity: .fast)
                }
                canvas.pinch(withScale: 0.5, velocity: -1)
                canvas.pinch(withScale: 8, velocity: 2) // 0.5× → 4×
                for _ in 0 ..< 3 {
                    canvas.swipeDown(velocity: .fast)
                }
                canvas.pinch(withScale: 0.25, velocity: -2) // back to 1×
            }
        }
    }
}
