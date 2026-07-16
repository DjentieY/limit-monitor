// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "claude-limits",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "ClaudeLimitsCore"),
        .executableTarget(name: "claude-limits", dependencies: ["ClaudeLimitsCore"]),
        .executableTarget(name: "checks", dependencies: ["ClaudeLimitsCore"]),
    ]
)
