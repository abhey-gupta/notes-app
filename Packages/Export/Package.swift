// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Export",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "Export", targets: ["Export"])],
    dependencies: [
        .package(path: "../InkModel"),
        .package(path: "../InkGeometry"),
    ],
    targets: [
        .target(name: "Export", dependencies: ["InkModel", "InkGeometry"]),
        .testTarget(name: "ExportTests", dependencies: ["Export"]),
    ]
)
