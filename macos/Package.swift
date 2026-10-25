// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BetterEssentialSpace",
    platforms: [
        .macOS(.v26)
    ],
    targets: [
        .target(
            name: "BetterEssentialSpaceCore",
            path: "Sources/BetterEssentialSpaceCore"
        ),
        .executableTarget(
            name: "BetterEssentialSpace",
            dependencies: ["BetterEssentialSpaceCore"],
            path: "Sources/BetterEssentialSpace"
        ),
        .testTarget(
            name: "BetterEssentialSpaceTests",
            dependencies: ["BetterEssentialSpaceCore", "BetterEssentialSpace"],
            path: "Tests/BetterEssentialSpaceTests",
            resources: [
                .copy("Fixtures")
            ]
        ),
    ]
)
