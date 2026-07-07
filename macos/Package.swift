// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "ClaudeIsland",
    platforms: [.macOS(.v11)],
    targets: [
        .executableTarget(
            name: "ClaudeIsland",
            path: "Sources/ClaudeIsland"
        )
    ]
)
