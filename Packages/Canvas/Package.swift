// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Canvas",
    platforms: [.iOS(.v26)],
    products: [.library(name: "Canvas", targets: ["Canvas"])],
    dependencies: [
        .package(path: "../InkEngine"),
        .package(path: "../InkModel"),
        .package(path: "../InkGeometry"),
        .package(path: "../Document"),
    ],
    targets: [
        .target(name: "Canvas", dependencies: ["InkEngine", "InkModel", "InkGeometry", "Document"]),
        .testTarget(name: "CanvasTests", dependencies: ["Canvas"]),
    ]
)
