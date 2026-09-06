// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DiskLens",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DiskLens",
            path: "Sources/DiskLens",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
