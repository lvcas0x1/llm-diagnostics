// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LLMUsageBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "LLMUsageBar",
            path: "Sources/LLMUsageBar"
        ),
        .testTarget(
            name: "LLMUsageBarTests",
            dependencies: ["LLMUsageBar"],
            path: "Tests/LLMUsageBarTests"
        )
    ]
)
