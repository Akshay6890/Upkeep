// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "UpkeepCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "UpkeepCore", targets: ["UpkeepCore"]),
        .executable(name: "upkeep-cli", targets: ["UpkeepCLI"]),
    ],
    targets: [
        .target(name: "UpkeepCore"),
        .executableTarget(name: "UpkeepCLI", dependencies: ["UpkeepCore"]),
        .testTarget(name: "UpkeepCoreTests", dependencies: ["UpkeepCore"]),
    ]
)
