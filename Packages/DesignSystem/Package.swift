// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DesignSystem",
    platforms: [.iOS(.v26)],
    products: [.library(name: "DesignSystem", targets: ["DesignSystem"])],
    dependencies: [
    ],
    targets: [
        .target(name: "DesignSystem", dependencies: []),
        .testTarget(name: "DesignSystemTests", dependencies: ["DesignSystem"]),
    ]
)
