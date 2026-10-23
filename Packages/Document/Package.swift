// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Document",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "Document", targets: ["Document"])],
    dependencies: [
        .package(path: "../InkModel"),
    ],
    targets: [
        .target(name: "Document", dependencies: ["InkModel"]),
        .testTarget(name: "DocumentTests", dependencies: ["Document", "InkModel"]),
    ]
)
