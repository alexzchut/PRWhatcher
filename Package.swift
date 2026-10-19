// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PRWatcher",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "PRWatcherCore"),
        .executableTarget(name: "PRWatcher", dependencies: ["PRWatcherCore"]),
        .testTarget(name: "PRWatcherCoreTests", dependencies: ["PRWatcherCore"]),
    ]
)
