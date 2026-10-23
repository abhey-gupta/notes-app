import Perf
import SwiftUI

@main
struct NotespaceApp: App {
    init() {
        Perf.markLaunchStart()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .onAppear {
                    Perf.markFirstFrame()
                    Perf.startMetricKit()
                }
                .perfHUD()
        }
    }
}
