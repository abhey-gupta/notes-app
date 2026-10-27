// swift-tools-version: 6.2
import PackageDescription

/// `PageLayout`, `PageWindow` and `PageResidency` are pure Swift and test headlessly on macOS (`swift test`);
/// the UIKit host (`CanvasHostView`, `ThumbnailService`) is iOS-only and compiles out elsewhere (`#if canImport(UIKit)`).
let iOS = TargetDependencyCondition.when(platforms: [.iOS])

let package = Package(
    name: "Canvas",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "Canvas", targets: ["Canvas"])],
    dependencies: [
        .package(path: "../InkEngine"),
        .package(path: "../InkGeometry"),
        .package(path: "../InkModel"),
        .package(path: "../Document"),
        .package(path: "../Perf"),
        // Test-only: the real engine renders thumbnail fixtures; FixtureGen builds the 300-page regen case.
        .package(path: "../InkEnginePencilKit"),
        .package(path: "../Fixtures"),
    ],
    targets: [
        .target(
            name: "Canvas",
            dependencies: [
                "InkModel",
                "Document",
                .product(name: "InkEngine", package: "InkEngine", condition: iOS),
                .product(name: "InkGeometry", package: "InkGeometry", condition: iOS),
                .product(name: "Perf", package: "Perf", condition: iOS),
            ]
        ),
        .testTarget(
            name: "CanvasTests",
            dependencies: [
                "Canvas",
                "Document",
                "InkModel",
                .product(name: "InkEnginePencilKit", package: "InkEnginePencilKit", condition: iOS),
                .product(name: "InkEngineTestSupport", package: "InkEngine", condition: iOS),
                .product(name: "FixtureGen", package: "Fixtures", condition: iOS),
            ]
        ),
    ]
)
