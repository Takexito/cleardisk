// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClearDisk",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "ClearDiskShared",
            path: "Sources/Shared"
        ),
        .executableTarget(
            name: "ClearDisk",
            dependencies: ["ClearDiskShared"],
            path: "Sources/ClearDisk"
        )
    ]
)
