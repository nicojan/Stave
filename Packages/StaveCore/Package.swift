// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StaveCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "StaveCore", targets: ["StaveCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", .upToNextMajor(from: "7.0.0")),
    ],
    targets: [
        .target(
            name: "StaveCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "StaveCoreTests",
            dependencies: ["StaveCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
