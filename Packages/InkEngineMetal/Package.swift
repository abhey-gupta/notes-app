// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "InkEngineMetal",
    platforms: [.iOS(.v26)],
    products: [.library(name: "InkEngineMetal", targets: ["InkEngineMetal"])],
    dependencies: [
        .package(path: "../InkEngine"),
        .package(path: "../InkModel"),
        .package(path: "../InkGeometry"),
    ],
    targets: [
        .target(name: "InkEngineMetal", dependencies: ["InkEngine", "InkModel", "InkGeometry"]),
        .testTarget(name: "InkEngineMetalTests", dependencies: ["InkEngineMetal"]),
    ]
)
