// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StaveCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "StaveCore", targets: ["StaveCore"]),
        .library(name: "StaveWeb", targets: ["StaveWeb"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        // Chorus's extracted web engine, pinned to a release tag.
        .package(url: "https://github.com/nicojan/Chorus.git", exact: "1.5.36"),
    ],
    targets: [
        .target(
            name: "StaveCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(
            name: "StaveWeb",
            dependencies: [
                "StaveCore",
                .product(name: "ChorusEngine", package: "Chorus"),
            ]
        ),
        .testTarget(
            name: "StaveWebTests",
            dependencies: ["StaveWeb", "StaveCore"]
        ),
        .testTarget(
            name: "StaveCoreTests",
            dependencies: ["StaveCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
