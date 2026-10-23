// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Tools",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "Tools", targets: ["Tools"])],
    dependencies: [
        .package(path: "../InkModel"),
        .package(path: "../InkGeometry"),
    ],
    targets: [
        .target(name: "Tools", dependencies: ["InkModel", "InkGeometry"]),
        .testTarget(name: "ToolsTests", dependencies: ["Tools"]),
    ]
)
