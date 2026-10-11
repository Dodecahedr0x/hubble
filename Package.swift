// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Hubble",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Hubble", path: "Sources/Hubble"),
        .testTarget(name: "HubbleTests", dependencies: ["Hubble"], path: "Tests/HubbleTests"),
    ]
)
