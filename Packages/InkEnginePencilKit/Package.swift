// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "InkEnginePencilKit",
    platforms: [.iOS(.v26)],
    products: [.library(name: "InkEnginePencilKit", targets: ["InkEnginePencilKit"])],
    dependencies: [
        .package(path: "../InkEngine"),
        .package(path: "../InkModel"),
        .package(path: "../InkGeometry"),
        .package(path: "../Document"),
    ],
    targets: [
        .target(name: "InkEnginePencilKit", dependencies: ["InkEngine", "InkModel", "InkGeometry"]),
        .testTarget(
            name: "InkEnginePencilKitTests",
            dependencies: [
                "InkEnginePencilKit",
                .product(name: "InkEngineTestSupport", package: "InkEngine"),
                .product(name: "InkGeometry", package: "InkGeometry"),
                // Round trips through the file format (#71).
                .product(name: "Document", package: "Document"),
            ]
        ),
    ]
)
