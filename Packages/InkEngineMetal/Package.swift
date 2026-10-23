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
        .package(path: "../Perf"),
        // Tests only: cross-checks renders against the PencilKit adapter (ARCHITECTURE.md §13).
        .package(path: "../InkEnginePencilKit"),
        // Tests only: realistic 100-page notebook for the tile scroll simulation (ARCHITECTURE.md §12).
        .package(path: "../Fixtures"),
    ],
    targets: [
        // `Shaders/*.metal` compile into the module bundle's default library at build time.
        .target(name: "InkEngineMetal", dependencies: ["InkEngine", "InkModel", "InkGeometry", "Perf"]),
        .testTarget(
            name: "InkEngineMetalTests",
            dependencies: [
                "InkEngineMetal",
                .product(name: "InkEngineTestSupport", package: "InkEngine"),
                "InkEnginePencilKit",
                .product(name: "FixtureGen", package: "Fixtures"),
            ],
            resources: [.copy("Goldens")]
        ),
    ]
)
