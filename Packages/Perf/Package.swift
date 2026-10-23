// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Perf",
    platforms: [.iOS(.v26)],
    products: [.library(name: "Perf", targets: ["Perf"])],
    dependencies: [
    ],
    targets: [
        .target(name: "Perf", dependencies: []),
        .testTarget(name: "PerfTests", dependencies: ["Perf"]),
    ]
)
