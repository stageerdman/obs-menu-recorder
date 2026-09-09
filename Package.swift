// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RecBar",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "RecBar",
            path: "Sources/RecBar"
        )
    ]
)
