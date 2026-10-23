// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "InkModel",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "InkModel", targets: ["InkModel"])],
    dependencies: [
    ],
    targets: [
        .target(name: "InkModel", dependencies: []),
        .testTarget(name: "InkModelTests", dependencies: ["InkModel"]),
    ]
)
