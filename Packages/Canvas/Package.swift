// swift-tools-version: 6.2
import PackageDescription

// `PageLayout` and `PageWindow` are pure Swift and test headlessly on macOS (`swift test`); the UIKit host
// (`CanvasHostView`, `PageResidency`) is iOS-only and compiles out elsewhere (`#if canImport(UIKit)`).
let iOS = TargetDependencyCondition.when(platforms: [.iOS])

let package = Package(
    name: "Canvas",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "Canvas", targets: ["Canvas"])],
    dependencies: [
        .package(path: "../InkEngine"),
        .package(path: "../InkModel"),
        .package(path: "../Document"),
        .package(path: "../Perf"),
    ],
    targets: [
        .target(
            name: "Canvas",
            dependencies: [
                "InkModel",
                "Document",
                .product(name: "InkEngine", package: "InkEngine", condition: iOS),
                .product(name: "Perf", package: "Perf", condition: iOS),
            ]
        ),
        .testTarget(name: "CanvasTests", dependencies: ["Canvas"]),
    ]
)
