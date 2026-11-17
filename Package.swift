// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FrameBoard",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "FrameBoard", targets: ["FrameBoard"])],
    targets: [
        .executableTarget(
            name: "FrameBoard",
            path: "Sources/FrameBoard",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
