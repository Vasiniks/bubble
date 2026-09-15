// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Bubble",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "Bubble",
            targets: ["Bubble"]
        )
    ],
    targets: [
        .executableTarget(
            name: "Bubble",
            path: "Sources/Bubble",
            resources: []
        )
    ]
)
