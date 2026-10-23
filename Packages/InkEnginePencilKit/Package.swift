// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "InkEnginePencilKit",
    platforms: [.iOS(.v26)],
    products: [.library(name: "InkEnginePencilKit", targets: ["InkEnginePencilKit"])],
    dependencies: [
        .package(path: "../InkEngine"),
        .package(path: "../InkModel"),
    ],
    targets: [
        .target(name: "InkEnginePencilKit", dependencies: ["InkEngine", "InkModel"]),
        .testTarget(name: "InkEnginePencilKitTests", dependencies: ["InkEnginePencilKit"]),
    ]
)
