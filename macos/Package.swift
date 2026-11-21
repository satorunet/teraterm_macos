// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "TeraMac",
    platforms: [.macOS(.v11)],
    targets: [
        // 正規表現ライブラリ 鬼車 (Oniguruma 6.9.10, BSD 2-Clause)。Tera Term のマクロと同じ正規表現にするため
        .target(name: "COniguruma", path: "Sources/COniguruma",
                exclude: ["data", "COPYING"],
                publicHeadersPath: "include",
                cSettings: [.headerSearchPath("."), .headerSearchPath("data"), .define("HAVE_CONFIG_H"),
                            .unsafeFlags(["-w"])]),
        // Tera Term のファイル転送プロトコル (ttpfile/ の XMODEM/YMODEM/ZMODEM/Kermit/B-Plus/Quick-VAN, BSD 3-Clause)
        .target(name: "CTeraFile", path: "Sources/CTeraFile",
                exclude: ["LICENSE"],
                sources: ["ttpfile", "glue"],
                publicHeadersPath: "include",
                cSettings: [.headerSearchPath("compat"), .headerSearchPath("ttpfile"), .headerSearchPath("glue"),
                            .unsafeFlags(["-w"])],
                cxxSettings: [.headerSearchPath("compat"), .headerSearchPath("ttpfile"), .headerSearchPath("glue"),
                              .unsafeFlags(["-w"])],
                linkerSettings: [.linkedLibrary("iconv")]),
        .target(name: "TeraCore", dependencies: ["COniguruma", "CTeraFile"], path: "Sources/TeraCore",
                swiftSettings: [.unsafeFlags(["-enforce-exclusivity=unchecked"], .when(configuration: .release))]),
        .target(name: "TeraUninstall", path: "Sources/TeraUninstall"),
        .executableTarget(name: "TeraMac", dependencies: ["TeraCore", "TeraUninstall"], path: "Sources/TeraMac"),
        .testTarget(name: "TeraCoreTests", dependencies: ["TeraCore"], path: "Tests/TeraCoreTests"),
    ]
)
