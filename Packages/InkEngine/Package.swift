// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "InkEngine",
    platforms: [.iOS(.v26)],
    products: [.library(name: "InkEngine", targets: ["InkEngine"])],
    dependencies: [
        .package(path: "../InkModel"),
        .package(path: "../InkGeometry"),
    ],
    targets: [
        .target(name: "InkEngine", dependencies: ["InkModel", "InkGeometry"]),
        .testTarget(name: "InkEngineTests", dependencies: ["InkEngine"]),
    ]
)
