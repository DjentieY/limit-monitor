// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "limit-monitor",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "LimitMonitorCore"),
        .executableTarget(name: "limit-monitor", dependencies: ["LimitMonitorCore"]),
        .executableTarget(name: "checks", dependencies: ["LimitMonitorCore"]),
    ]
)
