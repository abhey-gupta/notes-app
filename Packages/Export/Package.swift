// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Export",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "Export", targets: ["Export"])],
    dependencies: [
        .package(path: "../InkModel"),
        .package(path: "../InkGeometry"),
        // Test-only: realistic handwriting for the size and quality regression tests.
        .package(path: "../Fixtures"),
    ],
    targets: [
        .target(name: "Export", dependencies: ["InkModel", "InkGeometry"]),
        .testTarget(
            name: "ExportTests",
            dependencies: ["Export", "InkGeometry", .product(name: "FixtureGen", package: "Fixtures")]
        ),
    ]
)
