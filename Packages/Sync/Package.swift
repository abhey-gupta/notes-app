// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Sync",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "Sync", targets: ["Sync"])],
    dependencies: [
        .package(path: "../InkModel"),
        .package(path: "../Document"),
        .package(path: "../Library"),
    ],
    targets: [
        .target(name: "Sync", dependencies: ["InkModel", "Document", "Library"]),
        .testTarget(name: "SyncTests", dependencies: ["Sync", "InkModel", "Document", "Library"]),
    ]
)
