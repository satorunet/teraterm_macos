// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "TeraMac",
    platforms: [.macOS(.v11)],
    targets: [
        .target(name: "TeraCore", path: "Sources/TeraCore"),
        .executableTarget(name: "TeraMac", dependencies: ["TeraCore"], path: "Sources/TeraMac"),
        .testTarget(name: "TeraCoreTests", dependencies: ["TeraCore"], path: "Tests/TeraCoreTests"),
    ]
)
