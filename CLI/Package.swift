// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BossCLI",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        // 本地依赖
    ],
    targets: [
        .executableTarget(
            name: "boss",
            dependencies: [],
            path: ".",
            sources: ["main.swift"]
        )
    ]
)
