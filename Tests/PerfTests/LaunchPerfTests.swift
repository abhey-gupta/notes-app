import XCTest

/// Relative regression signal only; absolute budgets are verified on device (ARCHITECTURE.md §12).
final class LaunchPerfTests: XCTestCase {
    @MainActor
    func testColdLaunch() {
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)]) {
            XCUIApplication().launch()
        }
    }
}
