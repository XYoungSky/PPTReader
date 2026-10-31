// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PPTReader",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PPTReader",
            path: "Sources/PPTReader"
        )
    ]
)
