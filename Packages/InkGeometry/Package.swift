// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "InkGeometry",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "InkGeometry", targets: ["InkGeometry"])],
    dependencies: [
        .package(path: "../InkModel"),
    ],
    targets: [
        .target(name: "InkGeometry", dependencies: ["InkModel"]),
        .testTarget(name: "InkGeometryTests", dependencies: ["InkGeometry"]),
    ]
)
