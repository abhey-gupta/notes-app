// swift-tools-version: 6.2
import PackageDescription

/// `EditPipeline`: the one serial path every notebook change takes (store → mirror → history).
/// Foundation only, so it tests headlessly against a real `DocumentStore` in a temp dir.
let package = Package(
    name: "Editing",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "Editing", targets: ["Editing"])],
    dependencies: [
        .package(path: "../InkModel"),
        .package(path: "../Document"),
        .package(path: "../Tools"),
    ],
    targets: [
        .target(name: "Editing", dependencies: ["InkModel", "Document", "Tools"]),
        .testTarget(name: "EditingTests", dependencies: ["Editing", "InkModel", "Document", "Tools"]),
    ]
)
