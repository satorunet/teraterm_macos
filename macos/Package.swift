// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "TeraMac",
    platforms: [.macOS(.v11)],
    targets: [
        .target(name: "TeraCore", path: "Sources/TeraCore"),
        .target(name: "TeraUninstall", path: "Sources/TeraUninstall"),
        .executableTarget(name: "TeraMac", dependencies: ["TeraCore", "TeraUninstall"], path: "Sources/TeraMac"),
        .testTarget(name: "TeraCoreTests", dependencies: ["TeraCore"], path: "Tests/TeraCoreTests"),
    ]
)
