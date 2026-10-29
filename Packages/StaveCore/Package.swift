// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StaveCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "StaveCore", targets: ["StaveCore"]),
    ],
    dependencies: [
        // Capped below 7.9.0: GRDB 7.9+ declares swift-tools-version 6.1, and CI's
        // macOS 14 runner has Xcode 16.2 (Swift 6.0). Drop the cap when macOS 14 CI goes.
        .package(url: "https://github.com/groue/GRDB.swift", "7.0.0"..<"7.9.0"),
    ],
    targets: [
        .target(
            name: "StaveCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "StaveCoreTests",
            dependencies: ["StaveCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
