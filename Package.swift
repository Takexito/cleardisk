// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClearDisk",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "Shared",
            path: "Sources/Shared"
        ),
        .executableTarget(
            name: "ClearDisk",
            dependencies: ["Shared"],
            path: "Sources/ClearDisk"
        )
    ]
)
