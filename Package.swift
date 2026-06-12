// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "MusicPlayer",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MusicPlayer", targets: ["MusicPlayer"])
    ],
    targets: [
        .executableTarget(
            name: "MusicPlayer",
            path: "Sources/MusicPlayer"
        )
    ]
)
