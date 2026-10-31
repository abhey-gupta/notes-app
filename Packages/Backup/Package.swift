// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Backup",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "Backup", targets: ["Backup"])],
    dependencies: [
        .package(path: "../InkModel"),
        .package(path: "../Document"),
        .package(path: "../Library"),
    ],
    targets: [
        .target(name: "Backup", dependencies: ["InkModel", "Document", "Library"]),
        .testTarget(name: "BackupTests", dependencies: ["Backup", "InkModel", "Document", "Library"]),
    ]
)
