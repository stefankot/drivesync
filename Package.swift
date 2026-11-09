// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "drivesync",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "drivesync", path: "Sources/drivesync")
    ]
)
