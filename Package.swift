// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PPTReader",
    platforms: [.macOS(.v14)],
    dependencies: [
        // 本机 Whisper 转写（Core ML，在神经网络引擎上运行）。只用其中的 WhisperKit 库。
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.1"),
    ],
    targets: [
        .executableTarget(
            name: "PPTReader",
            dependencies: [.product(name: "WhisperKit", package: "WhisperKit")],
            path: "Sources/PPTReader"
        ),
        .testTarget(
            name: "PPTReaderTests",
            dependencies: ["PPTReader"],
            path: "Tests/PPTReaderTests"
        ),
    ]
)
