// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacGPUMonitorTray",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MacGPUMonitorTray",
            resources: [.process("Resources")]
        )
    ]
)
