// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RecBar",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "RecBar",
            path: "Sources/RecBar"
        )
    ]
)
