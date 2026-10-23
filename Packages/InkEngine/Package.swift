// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "InkEngine",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "InkEngine", targets: ["InkEngine"]),
        // Shared render fixtures + palette for engine tests (#18 PencilKit, #19 Metal). Test targets only.
        .library(name: "InkEngineTestSupport", targets: ["InkEngineTestSupport"]),
    ],
    dependencies: [
        .package(path: "../InkModel"),
        .package(path: "../InkGeometry"),
    ],
    targets: [
        .target(name: "InkEngine", dependencies: ["InkModel", "InkGeometry"]),
        .target(name: "InkEngineTestSupport", dependencies: ["InkEngine", "InkModel"]),
        .testTarget(name: "InkEngineTests", dependencies: ["InkEngine", "InkEngineTestSupport"]),
    ]
)
