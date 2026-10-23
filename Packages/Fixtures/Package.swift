// swift-tools-version: 6.2
import PackageDescription

// Dev-only: synthetic notebooks for perf tests, dev and screenshots (ARCHITECTURE.md §12). Kept out of the
// app-linked packages; `FixtureGen` is a library so simulator perf tests can also generate in-process.
let package = Package(
    name: "Fixtures",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "FixtureGen", targets: ["FixtureGen"]),
        .executable(name: "notespace-fixtures", targets: ["notespace-fixtures"]),
    ],
    dependencies: [
        .package(path: "../InkModel"),
        .package(path: "../Document"),
    ],
    targets: [
        .target(name: "FixtureGen", dependencies: ["InkModel", "Document"]),
        .executableTarget(name: "notespace-fixtures", dependencies: ["FixtureGen", "InkModel"]),
        .testTarget(name: "FixtureGenTests", dependencies: ["FixtureGen", "Document", "InkModel"]),
    ]
)
