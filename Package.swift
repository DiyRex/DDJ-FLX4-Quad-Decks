// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FLX4Deck",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "FLX4Deck",
            path: "Sources/FLX4Deck",
            swiftSettings: [.unsafeFlags(["-swift-version", "5"])]
        ),
    ]
)
